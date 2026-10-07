# Confluent Platform on OpenShift via CFK with TLS

## Prerequisites

- An OpenShift cluster you can `oc login` to, with permission to create namespaces, secrets, and routes.
- CLI tools on your machine: `oc`, `helm`, `openssl`,
  `keytool` (ships with any JDK), `python3`, and `envsubst` (fills
  `parameters.env` values into the manifests). Install `envsubst` for your OS:

  | OS | Command |
  |---|---|
  | macOS | `brew install gettext && brew link --force gettext` |
  | RHEL / CentOS / Fedora | `sudo dnf install gettext` |
  | Debian / Ubuntu | `sudo apt-get install gettext-base` |
  | Alpine | `apk add gettext` |
- Registry credentials. For the default `docker.io`, a Docker Hub account (username + [PAT](https://app.docker.com/settings/personal-access-tokens)): anonymous pulls are rate-limited and this repo pulls several images. For an internal registry, its pull credentials.
- cert-manager (FKO's admission webhook needs it) is cluster-wide. Step 6
  installs the Red Hat cert-manager Operator from
  `flink/cert-manager-operator.yaml` only if cert-manager is not already on the
  cluster.
- CFK/FKO/CMF chart versions come from `parameters.env` -
  no separate install needed, `source` it as shown below.

## Before you start

Edit `parameters.env` for your environment (every parameter starts with
`CFLT_`). The manifests are filled in with `envsubst`, so there is nothing to
search-and-replace:

- **`CFLT_OCP_ROUTE_DOMAIN`**, the cluster's apps domain used for every Route.
  Find yours with:

  ```bash
  oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
  ```
- **`CFLT_REGISTRY`**, the image registry (default `docker.io`), and the
  component versions (`CFLT_CP_VERSION`, `CFLT_INIT_VERSION`,
  `CFLT_C3_VERSION`, `CFLT_FLINK_IMAGE`, `CFLT_FLINK_VERSION`, and the chart
  versions).
- **Registry credentials**: `CFLT_REGISTRY_USERNAME`, `CFLT_REGISTRY_PASSWORD`
  (a personal access token for Docker Hub) and `CFLT_REGISTRY_EMAIL`, used by
  the `oc create secret docker-registry` commands below. Don't commit real values.

Run all the steps below in the same shell: `parameters.env` is sourced once in
step 1 and `envsubst` reads those variables.

## Setup

### 1. Prerequisites

```bash
oc apply -f 00-namespaces.yaml

source parameters.env   # registry, route domain, component and chart versions

helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

oc create secret docker-registry dockerhub-secret \
  --docker-server="$CFLT_REGISTRY_SERVER" \
  --docker-username="$CFLT_REGISTRY_USERNAME" \
  --docker-password="$CFLT_REGISTRY_PASSWORD" \
  --docker-email="$CFLT_REGISTRY_EMAIL" \
  -n confluent

oc create secret docker-registry dockerhub-secret \
  --docker-server="$CFLT_REGISTRY_SERVER" \
  --docker-username="$CFLT_REGISTRY_USERNAME" \
  --docker-password="$CFLT_REGISTRY_PASSWORD" \
  --docker-email="$CFLT_REGISTRY_EMAIL" \
  -n operator

oc create secret docker-registry dockerhub-secret \
  --docker-server="$CFLT_REGISTRY_SERVER" \
  --docker-username="$CFLT_REGISTRY_USERNAME" \
  --docker-password="$CFLT_REGISTRY_PASSWORD" \
  --docker-email="$CFLT_REGISTRY_EMAIL" \
  -n flink

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  -n operator --version "$CFLT_CFK_CHART_VERSION" \
  --set image.registry="$CFLT_REGISTRY" \
  --set imagePullSecretRef="dockerhub-secret" \
  --set enableCMFDay2Ops=true \
  --set enableFlinkSQL=true \
  --set namespaced=true \
  --set namespaceList="{operator,confluent,flink}" \
  --set podSecurity.enabled=false
```

### 2. Generate certs

```bash
cd certs
./generate-certs.sh
# override the default password: STORE_PASSWORD=yourpassword ./generate-certs.sh
```

Covers kraftcontroller, kafka, schemaregistry, controlcenter, cmf.

### 3. Load certs into the kubernetes cluster

```bash
./create-secrets.sh
```

Creates `tls-kraftcontroller`, `tls-kafka`, `tls-controlcenter`,
`connect-ca`, `sr-ssl-jks` in `confluent`, and `cmf-day2-tls`, `cmf-keystore`,
`cmf-truststore`, `flink-sr-tls` in `operator`.

### 4. Deploy KRaft / Kafka / Connect / Schema Registry / Control Center

Connect runs a custom image with the connector plugins baked in. Put the
plugin zips in `connect/plugins/` first, then build the image into the
cluster's internal registry:

```bash
cd ..
# Connect pulls its image from the internal registry (SA credentials) and the init
# container from $CFLT_REGISTRY, so the pod's service account needs both.
# (The secret is named dockerhub-secret throughout, whatever registry it points to.)
oc secrets link default dockerhub-secret --for=pull -n confluent
# Build args go on the BuildConfig (oc start-build --build-arg is not applied to binary builds),
# and the base image pull secret must be set on it explicitly.
oc new-build --name connect-custom --binary --strategy=docker --to=connect-custom:${CFLT_CP_VERSION}-plugins \
  --build-arg=CFLT_REGISTRY=$CFLT_REGISTRY --build-arg=CFLT_CP_VERSION=$CFLT_CP_VERSION -n confluent
oc set build-secret --pull bc/connect-custom dockerhub-secret -n confluent
oc start-build connect-custom --from-dir=connect --follow -n confluent
```


```bash
oc project confluent
envsubst < 01-confluent-platform.yaml | oc apply -f -

## This command may take a few minutes to deploy all the resources.
## Also if controlcenter pod is showing 2/3 availability, then try deleteing the pod.
## oc delete pod controlcenter-0

oc apply -f 02-connector.yaml

## Get all the public URLs for kafka and controlcenter
oc get routes

```

#### Optional: run a rebuilt Connect image

The Connect resource uses `pullPolicy: Always` on the `connect-custom` tag, so
a restarted pod pulls the latest build. After every rebuild, restart the pod
(one at a time if you run several replicas):

```bash
oc delete pod connect-0 -n confluent
```

Nothing else is needed, and re-applying `01-confluent-platform.yaml` does not
change which image is used.


### 5. Verify Kafka and Schema Registry from your laptop

```bash
cd certs
source ../parameters.env

## Make sure confluent-platform cli is available 
kafka-topics --bootstrap-server $CFLT_KAFKA_EXTERNAL_BOOTSTRAP --command-config client-ssl.properties --list
```

More commands: `certs/kafka-cli-commands.sh`.

Schema Registry sanity check (HTTPS via its route; only the CA is needed, no client cert):

```bash
curl --cacert generated/cacerts.pem https://schemaregistry.$CFLT_OCP_ROUTE_DOMAIN/subjects
# after the datagen connector in step 4 is running: ["stocks-value"]
```

### 6. Deploy FKO + CMF

```bash
cd ..

# FKO's admission webhook needs cert-manager, which is cluster-wide: install it only if absent.
# Check for a running controller, not the CRD: CRDs survive an uninstall.
if oc get deployment -A -l app.kubernetes.io/name=cert-manager -o name 2>/dev/null | grep -q .; then
  echo "cert-manager already present, skipping install"
else
  oc apply -f flink/cert-manager-operator.yaml
  until oc get deployment -n cert-manager -l app.kubernetes.io/name=cert-manager -o name 2>/dev/null | grep -q .; do sleep 5; done
  oc wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
fi

helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator \
  -n operator --version "$CFLT_FKO_CHART_VERSION" -f flink/fko-values.yaml \
  --set image.repository="$CFLT_REGISTRY/confluentinc/cp-flink-kubernetes-operator"

helm upgrade --install cmf confluentinc/confluent-manager-for-apache-flink \
  -n operator --version "$CFLT_CMF_CHART_VERSION" -f flink/cmf-values.yaml \
  --set image.repository="$CFLT_REGISTRY/confluentinc"

envsubst < flink/cmf-route.yaml | oc apply -f -
oc apply -f flink/cmfrestclass.yaml
```

### 7. Run a Flink workload, via CFK resources

`flink/flink-resources.yaml` defines the environment, secret, secret mapping,
Kafka catalog, Kafka database and compute pool as CFK custom resources (a
preview feature in CFK 3.3). CFK syncs them to CMF through the `default`
CMFRestClass from step 6.

```bash
envsubst < flink/flink-resources.yaml | oc apply -f -

# each should show cfkInternalState: CREATED
oc get flinkenvironment,flinksecret,flinkenvironmentsecretmapping,flinkkafkacatalog,flinkkafkadatabase,flinkcomputepool -n operator

# Flink pods pull cp-flink-sql from $CFLT_REGISTRY as the service account CMF creates
# for the environment; without this they fail with "too many requests to registry"
# (Docker Hub) or an authentication error (private registry).
oc secrets link cmf-env-sa-flink-env dockerhub-secret --for=pull -n flink
```

- The catalog reaches Schema Registry over HTTPS using the `flink-sr-tls`
  Secret from `create-secrets.sh` (CA only; Schema Registry doesn't require a
  client cert).
- The database uses Kafka's internal plaintext listener (`kafka.confluent.svc.cluster.local:9071`),
  so it needs no secret.
- The `FlinkSecret`, its mapping and the catalog's `connectionSecretId` all use
  the same name (`sr-tls`): CFK resolves `connectionSecretId` to the
  `FlinkSecret` by name, and CMF silently ignores a catalog whose mapping is missing.

**Run SQL** in the CMF UI (`oc get routes -n operator` for its URL), in the `flink-env` environment's SQL workspace, against `compute-pool`:
```sql
SHOW TABLES;
```

```sql
SELECT * FROM stocks;
```

Check the Flink SQL pods:

```bash
oc get pods -n flink
```

`stocks` is the topic `02-connector.yaml` already creates and the datagen connector already writes to - a Kafka catalog/database surfaces existing topics as tables automatically, no DDL needed. 

## Cleanup

If you did step 7, delete its resources first so CFK removes them from CMF
(CFK deletes them in dependency order) - nothing else below removes them.

Reverse order of setup otherwise: Flink/CMF first, then the platform,
then certs and secrets.

```bash
# Flink / CMF
oc delete -f flink/flink-resources.yaml
oc delete -f flink/cmfrestclass.yaml
oc delete -f flink/cmf-route.yaml
helm uninstall cmf -n operator
helm uninstall cp-flink-kubernetes-operator -n operator

# Confluent Platform
oc delete -f 02-connector.yaml
oc delete -f 01-confluent-platform.yaml

# TLS secrets
oc delete secret tls-kraftcontroller tls-kafka tls-controlcenter connect-ca sr-ssl-jks -n confluent
oc delete secret cmf-day2-tls cmf-keystore cmf-truststore flink-sr-tls -n operator

# generated certs on disk
rm -rf certs/generated
```

Leave alone unless you're tearing down everything, not just this variant
- `confluent`/`operator`/`flink` namespaces, `dockerhub-secret`,
cert-manager, and the CFK operator itself are shared with `quickstart/`
and `security/`:

```bash
helm uninstall confluent-operator -n operator
# only if step 6 installed cert-manager and nothing else on the cluster uses it
oc delete -f flink/cert-manager-operator.yaml
oc delete secret dockerhub-secret -n confluent
oc delete secret dockerhub-secret -n operator
oc delete secret dockerhub-secret -n flink
oc delete -f 00-namespaces.yaml
```
