#!/usr/bin/env bash
# Generates a self-signed root CA and server certs for KRaftController,
# Kafka, Schema Registry, Control Center, and CMF.
#
# Output layout (all under ./generated, gitignored - these are private keys):
#   ca-key.pem, cacerts.pem            <- your CA (cacerts.pem doubles as
#                                         the PEM truststore - just the CA cert)
#   kraftcontroller-key.pem, kraftcontroller-server.pem  <- controller listener cert
#   kafka-key.pem, kafka-server.pem      <- Kafka's mTLS listener cert
#   schemaregistry-key.pem, schemaregistry-server.pem  <- Schema Registry's https listener cert (PEM)
#   sr-keystore.jks, sr-truststore.jks, sr-jksPassword.txt  <- same cert as JKS,
#                                         the format of Schema Registry's tls.secretRef secret
#   controlcenter-key.pem, controlcenter-server.pem  <- Control Center's cert
#   cmf-key.pem, cmf-server.pem          <- CMF's cert (PEM)
#   cmf-keystore.jks, cmf-truststore.jks <- CMF's cert, JKS - its Helm chart's
#                                         cmf.ssl fields require JKS specifically,
#                                         this is the one exception to "PEM only"
#                                         in this directory, not a style choice
#   client-appclient.pem, client-appclient-key.pem  <- example client cert
#   client-appclient-full.pem            <- same cert+key combined (Kafka's PEM
#                                         keystore loader needs both in one file)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../parameters.env"

NAMESPACE="confluent"
SVC_DOMAIN="svc.cluster.local"
ROUTE_DOMAIN="${CFLT_OCP_ROUTE_DOMAIN}"
DAYS=365
STORE_PASSWORD="${STORE_PASSWORD:-confluentpass}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generated"

mkdir -p "$OUT"
cd "$OUT"

echo "==> Generating root CA"
openssl genrsa -out ca-key.pem 2048
openssl req -x509 -new -nodes -key ca-key.pem -days "$DAYS" \
  -out cacerts.pem \
  -subj "/C=US/ST=CA/L=SF/O=Confluent/OU=Kafka/CN=kafka-ca"

# $1 = component name, $2 = CN, $3... = extra SAN DNS entries (beyond the
# standard <name>, <name>.confluent.svc.cluster.local, *.<name>.confluent.svc.cluster.local)
gen_server_cert() {
  local name="$1" cn="$2"
  shift 2
  local extra_sans=("$@")

  echo "==> Generating server cert for $name (CN=$cn)"
  openssl genrsa -out "${name}-key.pem" 2048
  openssl req -new -key "${name}-key.pem" -out "${name}.csr" -subj "/CN=${cn}"

  {
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=serverAuth,clientAuth"
    printf 'subjectAltName=DNS:%s,DNS:%s.%s.%s,DNS:*.%s.%s.%s' \
      "$name" "$name" "$NAMESPACE" "$SVC_DOMAIN" "$name" "$NAMESPACE" "$SVC_DOMAIN"
    if [ "${#extra_sans[@]}" -gt 0 ]; then
      for san in "${extra_sans[@]}"; do
        printf ',%s' "$san"
      done
    fi
    echo
  } > "${name}-ext.cnf"

  openssl x509 -req -in "${name}.csr" -CA cacerts.pem -CAkey ca-key.pem -CAcreateserial \
    -out "${name}-server.pem" -days "$DAYS" -extfile "${name}-ext.cnf"
}

gen_server_cert kraftcontroller kraftcontroller

# Kafka's cert needs to work both for in-cluster service DNS (used by the
# plaintext listener's peers too, harmless) and the OpenShift Route
# hostnames for the mTLS external listener:
#   bootstrap -> kafka.<ROUTE_DOMAIN>            (bootstrapPrefix defaults to cluster name "kafka")
#   brokers   -> b0.<ROUTE_DOMAIN>, b1..., b2...  (brokerPrefix defaults to "b", 3 replicas)
gen_server_cert kafka kafka \
  "DNS:kafka.${ROUTE_DOMAIN}" \
  "DNS:b0.${ROUTE_DOMAIN}" "DNS:b1.${ROUTE_DOMAIN}" "DNS:b2.${ROUTE_DOMAIN}" \
  "DNS:*.${ROUTE_DOMAIN}"

# Schema Registry has no Route; it needs in-cluster service DNS (plus the
# default route hostname, harmless).
gen_server_cert schemaregistry schemaregistry "DNS:schemaregistry.${ROUTE_DOMAIN}"

# Schema Registry's tls.secretRef (01-confluent-platform.yaml) takes a JKS secret:
# keystore.jks, truststore.jks and jksPassword.txt.
echo "==> Generating Schema Registry keystore.jks / truststore.jks (password: ${STORE_PASSWORD})"
rm -f schemaregistry.p12 sr-keystore.jks sr-truststore.jks sr-jksPassword.txt
openssl pkcs12 -export \
  -in schemaregistry-server.pem -inkey schemaregistry-key.pem \
  -out schemaregistry.p12 -name schemaregistry -passout "pass:${STORE_PASSWORD}"
keytool -importkeystore -noprompt \
  -srckeystore schemaregistry.p12 -srcstoretype PKCS12 -srcstorepass "$STORE_PASSWORD" \
  -destkeystore sr-keystore.jks -deststoretype JKS \
  -deststorepass "$STORE_PASSWORD" -destkeypass "$STORE_PASSWORD"
keytool -importcert -noprompt -trustcacerts -alias caroot \
  -file cacerts.pem -keystore sr-truststore.jks -storepass "$STORE_PASSWORD"
rm -f schemaregistry.p12
# CFK reads jksPassword.txt as a Properties file, so it needs a key=value line.
echo "jksPassword=${STORE_PASSWORD}" > sr-jksPassword.txt

# Control Center's route uses the default prefix "controlcenter":
#   controlcenter.<ROUTE_DOMAIN>
gen_server_cert controlcenter controlcenter "DNS:controlcenter.${ROUTE_DOMAIN}"

# CMF's Helm chart always names its Service "cmf-service" regardless of
# release name (confirmed via `helm template`), plus its own Route hostname.
gen_server_cert cmf cmf \
  "DNS:cmf-service" "DNS:cmf-service.operator.svc.cluster.local" "DNS:*.cmf-service.operator.svc.cluster.local" \
  "DNS:cmf.${ROUTE_DOMAIN}"

# CMF's Helm chart wants JKS, not PEM/PKCS12 - same cert, just repackaged.
echo "==> Generating CMF keystore.jks / truststore.jks (password: ${STORE_PASSWORD})"
rm -f cmf.p12 cmf-keystore.jks cmf-truststore.jks
openssl pkcs12 -export \
  -in cmf-server.pem -inkey cmf-key.pem \
  -out cmf.p12 -name cmf -passout "pass:${STORE_PASSWORD}"
keytool -importkeystore -noprompt \
  -srckeystore cmf.p12 -srcstoretype PKCS12 -srcstorepass "$STORE_PASSWORD" \
  -destkeystore cmf-keystore.jks -deststoretype JKS \
  -deststorepass "$STORE_PASSWORD" -destkeypass "$STORE_PASSWORD"
keytool -importcert -noprompt -trustcacerts -alias caroot \
  -file cacerts.pem -keystore cmf-truststore.jks -storepass "$STORE_PASSWORD"
rm -f cmf.p12

# Example client cert for testing Kafka's mTLS listener from your laptop.
# CN becomes the authenticated principal (RULE:.*CN=... in the Kafka CR).
gen_client_cert() {
  local name="$1" cn="$2"
  echo "==> Generating client cert for $name (CN=$cn)"
  openssl genrsa -out "client-${name}-key.pem" 2048
  # LibreSSL (macOS) emits PKCS#1; Kafka's PEM loader only reads PKCS#8.
  openssl pkcs8 -topk8 -nocrypt -in "client-${name}-key.pem" -out "client-${name}-key.p8" \
    && mv "client-${name}-key.p8" "client-${name}-key.pem"
  openssl req -new -key "client-${name}-key.pem" -out "client-${name}.csr" -subj "/CN=${cn}"
  {
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=clientAuth"
  } > "client-${name}-ext.cnf"
  openssl x509 -req -in "client-${name}.csr" -CA cacerts.pem -CAkey ca-key.pem -CAcreateserial \
    -out "client-${name}.pem" -days "$DAYS" -extfile "client-${name}-ext.cnf"
  rm -f "client-${name}.csr" "client-${name}-ext.cnf"

  # Kafka's PEM keystore loader (ssl.keystore.type=PEM) wants the cert AND
  # the private key in the ONE file pointed to by ssl.keystore.location -
  # there's no separate "ssl.key.location" config. Build that combined file.
  cat "client-${name}.pem" "client-${name}-key.pem" > "client-${name}-full.pem"
}

gen_client_cert appclient appclient

echo
echo "==> Done. Files are in: $OUT"
echo "    Run ./create-secrets.sh next to load these into Kubernetes secrets."
