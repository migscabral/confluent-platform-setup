# Deploying with a private Quay registry and local Helm chart files

Variant of [README.md](README.md) for an environment where:

- all container images come from a **private Quay** registry, and
- the Helm charts are installed from **`.tgz` files in a local directory**
  (no Helm repository, no internet access during deployment).

Steps 2, 3, 5 and 7 of the main README are unchanged. This file lists the
full sequence so it can be followed on its own, with the differences marked.
Quay host names below (`quay.example.com`) are placeholders.

Versions: Confluent Platform 8.3.1, CFK 3.3.0 (chart 0.1718.10), Control Center
2.5.0, FKO chart 1.150.3 (image 1.15.0-cp3), CMF 2.4.2, Flink SQL image
`1.19-cp10`.

## Prerequisites

- `oc` (logged in with cluster-admin rights), `helm`, `openssl`, `keytool`,
  `python3` and `envsubst` (see the main README).
- The images and the charts already downloaded, as described in
  [download-charts-images-connectors.md](download-charts-images-connectors.md).
- The four connector zips in `connect/plugins/` (same guide).

## 1. Prepare Quay (once)

1. Create an **organization** named `confluentinc`. The manifests build image
   paths as `<registry>/confluentinc/<name>:<tag>`, so keeping this name means
   no manifest changes.
2. Push the images into it. Follow "Download container images" in
   [download-charts-images-connectors.md](download-charts-images-connectors.md)
   with:

   ```bash
   TARGET=quay.example.com/confluentinc
   podman login quay.example.com
   ```

   The 11 images end up as, for example,
   `quay.example.com/confluentinc/cp-server:8.3.1`. If the repositories are not
   created automatically on push, create them first as private repositories.
3. Create a **robot account** (for example `confluentinc+deployer`) and give it
   **Read** permission on the `confluentinc` organization's repositories. Its
   token is the pull credential used below.

## 2. Make the cluster trust Quay (only if Quay uses a private CA)

Without this, image pulls and the Connect build fail with `x509: certificate
signed by unknown authority`. Skip it if Quay has a publicly trusted certificate.

```bash
oc create configmap quay-ca -n openshift-config --from-file=quay.example.com=quay-ca.crt
oc patch image.config.openshift.io/cluster --type merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"quay-ca"}}}'
```

The key name is the registry host name (`host..port` if it is not on 443).
Nodes pick the change up gradually, so wait until it has rolled out before
continuing.

## 3. Edit `parameters.env`

```bash
cp parameters.env.example parameters.env
```

Then set:

```bash
export CFLT_REGISTRY=quay.example.com
export CFLT_REGISTRY_SERVER=quay.example.com
export CFLT_REGISTRY_USERNAME=confluentinc+deployer   # robot account
export CFLT_REGISTRY_PASSWORD=<robot token>
export CFLT_REGISTRY_EMAIL=unused@example.com
export CFLT_OCP_ROUTE_DOMAIN=<your apps domain>
```

`CFLT_FLINK_IMAGE` follows `CFLT_REGISTRY` automatically. Keep
`parameters.env` out of Git (it holds the token).

## 4. Charts: put the `.tgz` files in a local directory

Use the directory you downloaded them to, for example `openshift/charts/`:

```
charts/confluent-for-kubernetes-0.1718.10.tgz
charts/flink-kubernetes-operator-1.150.3.tgz
charts/confluent-manager-for-apache-flink-2.4.2.tgz
```

No `helm repo add` or `helm repo update` is needed.

## 5. Deploy

Run everything in one shell from the `openshift/` directory.

### 5.1 Namespaces, pull secret and CFK operator (main step 1)

```bash
oc apply -f 00-namespaces.yaml
source parameters.env

for ns in confluent operator flink; do
  oc create secret docker-registry dockerhub-secret \
    --docker-server="$CFLT_REGISTRY_SERVER" \
    --docker-username="$CFLT_REGISTRY_USERNAME" \
    --docker-password="$CFLT_REGISTRY_PASSWORD" \
    --docker-email="$CFLT_REGISTRY_EMAIL" \
    -n $ns
done

helm upgrade --install confluent-operator charts/confluent-for-kubernetes-0.1718.10.tgz \
  -n operator \
  --set image.registry="$CFLT_REGISTRY" \
  --set imagePullSecretRef="dockerhub-secret" \
  --set enableCMFDay2Ops=true \
  --set enableFlinkSQL=true \
  --set namespaced=true \
  --set namespaceList="{operator,confluent,flink}" \
  --set podSecurity.enabled=false
```

The secret keeps the name `dockerhub-secret` because the manifests and values
files use it, even though it now points at Quay.

### 5.2 Certificates and secrets (main steps 2 and 3)

```bash
cd certs
./generate-certs.sh
./create-secrets.sh
cd ..
```

### 5.3 Connect image and platform (main step 4)

The Connect image is built into the cluster's internal registry. Its base image
comes from Quay, so the build needs the pull secret.

```bash
oc secrets link default dockerhub-secret --for=pull -n confluent
oc new-build --name connect-custom --binary --strategy=docker --to=connect-custom:${CFLT_CP_VERSION}-plugins \
  --build-arg=CFLT_REGISTRY=$CFLT_REGISTRY --build-arg=CFLT_CP_VERSION=$CFLT_CP_VERSION -n confluent
oc set build-secret --pull bc/connect-custom dockerhub-secret -n confluent
oc start-build connect-custom --from-dir=connect --follow -n confluent

oc project confluent
envsubst < 01-confluent-platform.yaml | oc apply -f -
oc apply -f 02-connector.yaml
```

Optional: after a rebuild, restart the Connect pod (`oc delete pod connect-0 -n confluent`)
so it pulls the new image, as in the main README.

### 5.4 Verify (main step 5)

Same commands as the main README (`kafka-topics` over the route and the Schema
Registry `curl`).

### 5.5 cert-manager, FKO and CMF (main step 6)

cert-manager is cluster-wide. Install it only if absent; on a disconnected
cluster the Red Hat catalog must be mirrored first.

```bash
if oc get deployment -A -l app.kubernetes.io/name=cert-manager -o name 2>/dev/null | grep -q .; then
  echo "cert-manager already present, skipping install"
else
  oc apply -f flink/cert-manager-operator.yaml
  until oc get deployment -n cert-manager -l app.kubernetes.io/name=cert-manager -o name 2>/dev/null | grep -q .; do sleep 5; done
  oc wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
fi

helm upgrade --install cp-flink-kubernetes-operator charts/flink-kubernetes-operator-1.150.3.tgz \
  -n operator -f flink/fko-values.yaml \
  --set image.repository="$CFLT_REGISTRY/confluentinc/cp-flink-kubernetes-operator"

helm upgrade --install cmf charts/confluent-manager-for-apache-flink-2.4.2.tgz \
  -n operator -f flink/cmf-values.yaml \
  --set image.repository="$CFLT_REGISTRY/confluentinc"

envsubst < flink/cmf-route.yaml | oc apply -f -
oc apply -f flink/cmfrestclass.yaml
```

### 5.6 Flink resources (main step 7)

```bash
envsubst < flink/flink-resources.yaml | oc apply -f -
oc get flinkenvironment,flinksecret,flinkenvironmentsecretmapping,flinkkafkacatalog,flinkkafkadatabase,flinkcomputepool -n operator

# Flink pods pull cp-flink-sql from Quay as the service account CMF creates
oc secrets link cmf-env-sa-flink-env dockerhub-secret --for=pull -n flink
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ImagePullBackOff`, `unauthorized` | Robot account lacks Read on the repository, or the pod's namespace has no `dockerhub-secret` |
| `x509: certificate signed by unknown authority` | Quay's CA is not trusted yet (step 2), or the change has not rolled out to all nodes |
| `manifest unknown` / `not found` | The image or tag was not pushed to the `confluentinc` organization |
| Flink statement pods in `ImagePullBackOff` | `dockerhub-secret` not linked to `cmf-env-sa-flink-env` (step 5.6) |
| Connect build `PullBuilderImageFailed` | `oc set build-secret --pull` was not run, or Quay's CA is not trusted |
| `helm` cannot find the chart | Path to the `.tgz` is wrong; run from `openshift/` |

## Cleanup

Same as the main README. Charts are uninstalled by release name
(`helm uninstall <release> -n operator`), so the local `.tgz` files are not
needed for removal.
