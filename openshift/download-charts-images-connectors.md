# Download charts, container images and connector packages

Run these steps on a machine with internet access, then move the results to
your private Helm repository, container registry and artifact store (or to the
OpenShift internal registry, see [README-internal-registry.md](README-internal-registry.md)).
Versions are those of this deployment package: Confluent Platform 8.3.1,
CFK 3.3.0 (chart 0.1718.10), Control Center 2.5.0, FKO chart 1.150.3, CMF 2.4.2.

Prerequisites on the download machine: `helm`, `podman`, `curl`. On macOS
or Windows start the Podman VM once:

```bash
podman machine init    # first time only
podman machine start
```

```bash
cd <your-project-local-dir>/openshift
podman login docker.io         # avoids Docker Hub anonymous pull limits
```

## Download Helm charts

1. Pull the charts.

   ```bash
   mkdir -p confluent-charts && cd confluent-charts

   helm repo add confluentinc https://packages.confluent.io/helm
   helm repo update

   helm pull confluentinc/confluent-for-kubernetes --version 0.1718.10
   helm pull confluentinc/flink-kubernetes-operator --version 1.150.3
   helm pull confluentinc/confluent-manager-for-apache-flink --version 2.4.2
   ```

2. Verify the downloaded charts.

   ```bash
   for chart in ./*.tgz; do
     helm show chart "$chart"
     helm show crds "$chart" >/dev/null || true
     helm dependency list "$chart" || true
   done
   cd ..
   ```

3. Upload the charts to your private Helm repository, or keep the `.tgz`
   files and install from them (see step 5 of
   [README-internal-registry.md](README-internal-registry.md)).

## Download container images

The list matches `01-confluent-platform.yaml`, `parameters.env` and the
images the three charts deploy.

1. Pull the images. Use `--platform linux/amd64` because OpenShift nodes are
   normally x86_64, even if you download from an Apple Silicon Mac.

   ```bash
   images=(
     "confluentinc/confluent-operator:0.1718.10"
     "confluentinc/confluent-init-container:3.3.0"
     "confluentinc/cp-server:8.3.1"
     "confluentinc/cp-server-connect:8.3.1"
     "confluentinc/cp-schema-registry:8.3.1"
     "confluentinc/cp-enterprise-control-center-next-gen:2.5.0"
     "confluentinc/cp-enterprise-prometheus:2.5.0"
     "confluentinc/cp-enterprise-alertmanager:2.5.0"
     "confluentinc/cp-flink-kubernetes-operator:1.15.0-cp3"
     "confluentinc/cp-cmf:2.4.2"
     "confluentinc/cp-flink-sql:1.19-cp10"
   )
   for image in "${images[@]}"; do
     podman pull --platform linux/amd64 "docker.io/$image"
   done
   ```

   The FKO and CMF image tags are the defaults of the chart versions above.

2. Verify the downloaded images.

   ```bash
   for image in "${images[@]}"; do
     podman image inspect "docker.io/$image" --format '{{.RepoTags}} {{.Os}}/{{.Architecture}}'
   done
   ```

3. Upload the images to your private container registry.

   ```bash
   TARGET=registry.example.com/confluentinc   # your registry and project/path
   podman login registry.example.com

   for image in "${images[@]}"; do
     podman tag  "docker.io/$image" "$TARGET/${image#confluentinc/}"
     podman push "$TARGET/${image#confluentinc/}"
   done
   ```

   For the OpenShift internal registry use
   `TARGET=<registry-route-host>/confluentinc` (see
   [README-internal-registry.md](README-internal-registry.md), step 2),
   and log in with `podman login -u "$(oc whoami)" -p "$(oc whoami -t)" <registry-route-host>`.
   Then set `CFLT_REGISTRY` in `parameters.env` to the registry host only (the
   manifests add `/confluentinc/...`).

   **No direct connection between the two networks?** Save the images to one
   archive, transfer it, and load it on a machine that can reach the registry:

   ```bash
   podman save --multi-image-archive -o confluent-images.tar "${images[@]/#/docker.io/}"
   # on the other machine:
   podman load -i confluent-images.tar
   ```

   Then run the tag and push loop above.

## Download the connector packages

These are the zips baked into the Connect image (`connect/Dockerfile` copies
`connect/plugins/*.zip`).

1. Download the packages.

   ```bash
   mkdir -p confluent-connector-packages && cd confluent-connector-packages

   curl -fLO https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-datagen/versions/0.7.2/confluentinc-kafka-connect-datagen-0.7.2.zip
   curl -fLO https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-jdbc/versions/10.9.9/confluentinc-kafka-connect-jdbc-10.9.9.zip
   curl -fLO https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-s3/versions/12.1.11/confluentinc-kafka-connect-s3-12.1.11.zip
   curl -fLO https://hub-downloads.confluent.io/api/plugins/mongodb/kafka-connect-mongodb/versions/3.1.0/mongodb-kafka-connect-mongodb-3.1.0.zip
   ```

2. Verify the downloads.

   ```bash
   for z in *.zip; do unzip -tq "$z"; done
   shasum -a 256 *.zip
   cd ..
   ```

3. Upload them to your private artifact repository (for example Nexus,
   Artifactory or a plain HTTP server) and, on the machine that builds the
   Connect image, copy them into `connect/plugins/`:

   ```bash
   mkdir -p connect/plugins && cp confluent-connector-packages/*.zip connect/plugins/
   ```

   Then build the image as in step 4 of [README.md](README.md). The build
   installs from these local files and needs no access to Confluent Hub.

The JDBC connector package does not include every database driver (for example
MySQL or Oracle). This deployment creates no JDBC connector, so none is needed;
add the driver jar to the plugin directory if you use one.

## Not covered here

- **cert-manager:** the Red Hat cert-manager Operator comes from the OperatorHub
  catalog. On a disconnected cluster, mirror it with `oc-mirror`.
- **OpenShift base images** (builder, internal registry): provided by the cluster.
