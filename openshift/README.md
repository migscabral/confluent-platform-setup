# Confluent Platform on OpenShift via CFK with TLS

## Prerequisites

- An OpenShift cluster you can `oc login` to, with permission to create namespaces, secrets, and routes.
- CLI tools on your machine: `oc` (or `kubectl`), `helm`, `openssl`,
  `keytool` (ships with any JDK), `python3`.
- A Docker Hub account (username + [PAT](https://app.docker.com/settings/personal-access-tokens)) - anonymous `docker.io` pulls are rate-limited and this repo pulls several images.
- The Red Hat cert-manager Operator (FKO's admission webhook needs it) is
  installed in step 6 from `flink/cert-manager-operator.yaml`, unless it is
  already on the cluster.
- CFK/FKO/CMF chart versions come from `parameters.env` -
  no separate install needed, `source` it as shown below.

## Before you start

Two things are baked into the manifests as literal values, not
placeholders - swap them for your own before applying:

- **Cluster apps domain**, currently `apps.redhat.ibm.com`. Find yours with:

```bash
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
```
then:
  ```bash
  grep -rl 'apps.redhat.ibm.com' . \
    | xargs sed -i '' 's/apps\.redhat\.ibm\.com/YOUR_DOMAIN_HERE/g'
  ```
- **Docker Hub credentials** in the `kubectl create secret docker-registry`
  commands below - use your own username/PAT/email. Images are pulled
  from `docker.io`, and anonymous pulls are rate-limited.

## Setup

### 1. Prerequisites

```bash
kubectl apply -f 00-namespaces.yaml

source parameters.env   # CFK_CHART_VERSION, FKO_CHART_VERSION, CMF_CHART_VERSION

helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="dockerhub-username" \
  --docker-password="dockerhub-personal-access-token" \
  --docker-email="dockerhub-user-email" \
  -n confluent

kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="dockerhub-username" \
  --docker-password="dockerhub-personal-access-token" \
  --docker-email="dockerhub-user-email" \
  -n operator

kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="dockerhub-username" \
  --docker-password="dockerhub-personal-access-token" \
  --docker-email="dockerhub-user-email" \
  -n flink

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  -n operator --version "$CFK_CHART_VERSION" \
  --set image.registry=docker.io \
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
oc secrets link builder dockerhub-secret -n confluent   # base image pull from Docker Hub
# Connect pulls its image from the internal registry (SA credentials) and the init
# container from Docker Hub, so the pod's service account needs both.
oc secrets link default dockerhub-secret --for=pull -n confluent
oc new-build --name connect-custom --binary --strategy=docker --to=connect-custom:8.3.1-plugins -n confluent
oc start-build connect-custom --from-dir=connect --follow -n confluent
```


```bash
kubectl config set-context --current --namespace confluent
kubectl apply -f 01-confluent-platform.yaml

## This command may take a few minutes to deploy all the resources.
## Also if controlcenter pod is showing 2/3 availability, then try deleteing the pod.
## kubectl delete pod controlcenter-0

kubectl apply -f 02-connector.yaml

## Get all the public URLs for kafka and controlcenter
kubectl get routes

```


### 5. Verify Kafka and Schema Registry from your laptop

```bash
cd certs
BOOTSTRAP=kafka.apps.redhat.ibm.com:443

## Make sure confluent-platform cli is available 
kafka-topics --bootstrap-server $BOOTSTRAP --command-config client-ssl.properties --list
```

More commands: `certs/kafka-cli-commands.sh`.

Schema Registry sanity check (HTTPS via its route; only the CA is needed, no client cert):

```bash
curl --cacert generated/cacerts.pem https://schemaregistry.apps.redhat.ibm.com/subjects
# after the datagen connector in step 4 is running: ["stocks-value"]
```

### 6. Deploy FKO + CMF

```bash
cd ..

# provisions FKO's own admission-webhook certs
kubectl apply -f flink/cert-manager-operator.yaml
until kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator \
  -n operator --version "$FKO_CHART_VERSION" -f flink/fko-values.yaml

helm upgrade --install cmf confluentinc/confluent-manager-for-apache-flink \
  -n operator --version "$CMF_CHART_VERSION" -f flink/cmf-values.yaml

kubectl apply -f flink/cmf-route.yaml
kubectl apply -f flink/cmfrestclass.yaml
```

### 7. Run a Flink workload, via CFK resources

`flink/flink-resources.yaml` defines the environment, secret, secret mapping,
Kafka catalog, Kafka database and compute pool as CFK custom resources (a
preview feature in CFK 3.3). CFK syncs them to CMF through the `default`
CMFRestClass from step 6.

```bash
kubectl apply -f flink/flink-resources.yaml

# each should show cfkInternalState: CREATED
kubectl get flinkenvironment,flinksecret,flinkenvironmentsecretmapping,flinkkafkacatalog,flinkkafkadatabase,flinkcomputepool -n operator

# Flink pods pull cp-flink-sql from Docker Hub as the service account CMF creates
# for the environment; without this they fail with "too many requests to registry".
kubectl secrets link cmf-env-sa-flink-env dockerhub-secret --for=pull -n flink
```

- The catalog reaches Schema Registry over HTTPS using the `flink-sr-tls`
  Secret from `create-secrets.sh` (CA only; Schema Registry doesn't require a
  client cert).
- The database uses Kafka's internal plaintext listener (`kafka.confluent.svc.cluster.local:9071`),
  so it needs no secret.
- The `FlinkSecret`, its mapping and the catalog's `connectionSecretId` all use
  the same name (`sr-tls`): CFK resolves `connectionSecretId` to the
  `FlinkSecret` by name, and CMF silently ignores a catalog whose mapping is missing.

**Run SQL** in the CMF UI (`kubectl get routes -n operator` for its URL), in the `flink-env` environment's SQL workspace, against `compute-pool`:
```sql
SHOW TABLES;
```

```sql
SELECT * FROM stocks;
```

Check the running Pods for flink SQL
kubectl get pods -n flink

`stocks` is the topic `02-connector.yaml` already creates and the datagen connector already writes to - a Kafka catalog/database surfaces existing topics as tables automatically, no DDL needed. 

## Cleanup

If you did step 7, delete its resources first so CFK removes them from CMF
(CFK deletes them in dependency order) - nothing else below removes them.

Reverse order of setup otherwise: Flink/CMF first, then the platform,
then certs and secrets.

```bash
# Flink / CMF
kubectl delete -f flink/flink-resources.yaml
kubectl delete -f flink/cmfrestclass.yaml
kubectl delete -f flink/cmf-route.yaml
helm uninstall cmf -n operator
helm uninstall cp-flink-kubernetes-operator -n operator

# Confluent Platform
kubectl delete -f 02-connector.yaml
kubectl delete -f 01-confluent-platform.yaml

# TLS secrets
kubectl delete secret tls-kraftcontroller tls-kafka tls-controlcenter connect-ca sr-ssl-jks -n confluent
kubectl delete secret cmf-day2-tls cmf-keystore cmf-truststore flink-sr-tls -n operator

# generated certs on disk
rm -rf certs/generated
```

Leave alone unless you're tearing down everything, not just this variant
- `confluent`/`operator`/`flink` namespaces, `dockerhub-secret`,
cert-manager, and the CFK operator itself are shared with `quickstart/`
and `security/`:

```bash
helm uninstall confluent-operator -n operator
kubectl delete -f flink/cert-manager-operator.yaml
kubectl delete secret dockerhub-secret -n confluent
kubectl delete secret dockerhub-secret -n operator
kubectl delete secret dockerhub-secret -n flink
kubectl delete -f 00-namespaces.yaml
```
