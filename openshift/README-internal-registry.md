# Deploying with the OpenShift internal registry and an internal Helm source

Alternative to [README.md](README.md) for clusters that should not pull from
Docker Hub / the public Confluent Helm repo. Only the steps below differ; every
other step in the main README (certs, secrets, CRs, Flink resources, cleanup) is
unchanged.

Not yet validated end to end: the image mirroring, the permissions and the
Helm overrides below. Check the Helm overrides with `helm template` before
installing.

## Idea

The internal registry stores images as `<registry>/<project>/<name>:<tag>`. The
manifests use `${CFLT_REGISTRY}/confluentinc/<name>:<tag>`, so mirroring every
image into a project named **`confluentinc`** needs no manifest changes. Only
`CFLT_REGISTRY` changes.

## 1. Edit `parameters.env`

```bash
export CFLT_REGISTRY=image-registry.openshift-image-registry.svc:5000
```

`CFLT_FLINK_IMAGE` follows automatically. `CFLT_REGISTRY_SERVER`,
`CFLT_REGISTRY_USERNAME`, `CFLT_REGISTRY_PASSWORD` and `CFLT_REGISTRY_EMAIL`
are only needed by whoever mirrors from Docker Hub (step 2, option A).

## 2. Mirror the images (new step, before main step 1)

```bash
oc apply -f 00-namespaces.yaml
oc new-project confluentinc        # holds the mirrored images
source parameters.env

IMAGES="
cp-server:$CFLT_CP_VERSION
cp-server-connect:$CFLT_CP_VERSION
cp-schema-registry:$CFLT_CP_VERSION
confluent-init-container:$CFLT_INIT_VERSION
cp-enterprise-control-center-next-gen:$CFLT_C3_VERSION
cp-enterprise-prometheus:$CFLT_C3_VERSION
cp-enterprise-alertmanager:$CFLT_C3_VERSION
confluent-operator:$CFLT_CFK_CHART_VERSION
cp-flink-kubernetes-operator:1.15.0-cp3
cp-cmf:2.4.1
cp-flink-sql:1.19-cp10
"
```

The last three tags come from the FKO/CMF charts and the Flink image
setting. Confirm them with `helm template` (as in main step 6) if you change
chart versions.

**A. Cluster can reach Docker Hub.** Import once; the `local` reference policy
makes pods pull through the internal registry:

```bash
# if rate-limited, first: oc create secret docker-registry dockerhub-secret ... -n confluentinc
for i in $IMAGES; do
  oc import-image "$i" --from="docker.io/confluentinc/$i" --confirm \
    --reference-policy=local -n confluentinc
done
```

**B. Disconnected cluster.** Mirror from a workstation that can reach both
Docker Hub and the cluster's external registry route:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'
HOST=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
oc registry login --registry "$HOST"
for i in $IMAGES; do
  oc image mirror "docker.io/confluentinc/$i" "$HOST/confluentinc/$i"
done
```

## 3. Allow the other projects to pull

```bash
for ns in confluent operator flink; do
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$ns -n confluentinc
done
```

This also covers the `builder` account (Connect build) and the
`cmf-env-sa-flink-env` account (Flink pods).

## 4. Pull secrets: skip them

Compared with the main README:

- Main step 1: skip the three `oc create secret docker-registry` commands.
- Main step 4: skip `oc secrets link default dockerhub-secret` and
  `oc set build-secret --pull ...`.
- Main step 7: skip `oc secrets link cmf-env-sa-flink-env dockerhub-secret`.
- Do not pass `imagePullSecretRef` to the CFK chart. Override the secrets that
  the values files set, so no pod lists a pull secret that doesn't exist:

  ```bash
  # FKO
  --set imagePullSecrets=null
  # CMF
  --set imagePullSecretRef=null
  ```

## 5. Helm charts from an internal source

OpenShift has no built-in chart repository for these charts, and the integrated
registry is generally not suited to storing Helm charts (verify for your
version). Use one of:

**A. Vendored `.tgz` files (simplest, fully offline).** On a connected machine:

```bash
helm pull confluentinc/confluent-for-kubernetes --version "$CFLT_CFK_CHART_VERSION" -d charts/
helm pull confluentinc/flink-kubernetes-operator --version "$CFLT_FKO_CHART_VERSION" -d charts/
helm pull confluentinc/confluent-manager-for-apache-flink --version "$CFLT_CMF_CHART_VERSION" -d charts/
```

Then install from the files instead of the repo, with the same flags as the
main README:

```bash
helm upgrade --install confluent-operator charts/confluent-for-kubernetes-$CFLT_CFK_CHART_VERSION.tgz ...
helm upgrade --install cp-flink-kubernetes-operator charts/flink-kubernetes-operator-$CFLT_FKO_CHART_VERSION.tgz ...
helm upgrade --install cmf charts/confluent-manager-for-apache-flink-$CFLT_CMF_CHART_VERSION.tgz ...
```

**B. Your organisation's chart repository** (Nexus, Artifactory, Harbor, Quay):
publish the `.tgz` files there, then:

```bash
helm repo add internal <url>
helm upgrade --install confluent-operator internal/confluent-for-kubernetes --version "$CFLT_CFK_CHART_VERSION" ...
```

Replace `confluentinc/<chart>` with `internal/<chart>` in the main README
commands.

## 6. Other differences

- **Connect build (main step 4):** unchanged apart from the secret link. The
  `FROM` line resolves to the mirrored `cp-server-connect`, which the `builder`
  account can pull (step 3).
- **cert-manager Operator (main step 6):** comes from the `redhat-operators`
  OperatorHub catalog. On a disconnected cluster, mirror that catalog first
  (for example with `oc-mirror`).
- **Everything else** (steps 2, 3, 5, 7 and Cleanup of the main README) is
  unchanged.
