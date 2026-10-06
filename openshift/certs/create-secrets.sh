#!/usr/bin/env bash
# Loads the certs from ./generated into the Kubernetes secrets the CRs in
# ../01-confluent-platform.yaml and ../flink/ reference. Run
# ./generate-certs.sh first.
set -euo pipefail

NAMESPACE="confluent"
OPERATOR_NAMESPACE="operator"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generated"

create_secret() {
  local component="$1" ns="$2"
  oc create secret generic "tls-${component}" \
    --from-file=fullchain.pem="${DIR}/${component}-server.pem" \
    --from-file=privkey.pem="${DIR}/${component}-key.pem" \
    --from-file=cacerts.pem="${DIR}/cacerts.pem" \
    --namespace "$ns" \
    --dry-run=client -o yaml | oc apply -f -
}

create_secret "kraftcontroller" "$NAMESPACE"
create_secret "kafka" "$NAMESPACE"
create_secret "controlcenter" "$NAMESPACE"

# CA-only secret mounted into Connect so its Avro converter can trust Schema Registry.
oc create secret generic connect-ca -n "$NAMESPACE" \
  --from-file=cacerts.pem="${DIR}/cacerts.pem" \
  --dry-run=client -o yaml | oc apply -f -

# JKS secret for Schema Registry's tls.secretRef (../01-confluent-platform.yaml).
oc create secret generic sr-ssl-jks -n "$NAMESPACE" \
  --from-file=keystore.jks="${DIR}/sr-keystore.jks" \
  --from-file=truststore.jks="${DIR}/sr-truststore.jks" \
  --from-file=jksPassword.txt="${DIR}/sr-jksPassword.txt" \
  --dry-run=client -o yaml | oc apply -f -

# CFK's CMFRestClass (../flink/cmfrestclass.yaml) expects this secret name
# and PEM key convention, in the operator namespace where it lives.
oc create secret generic cmf-day2-tls -n "$OPERATOR_NAMESPACE" \
  --from-file=fullchain.pem="${DIR}/cmf-server.pem" \
  --from-file=privkey.pem="${DIR}/cmf-key.pem" \
  --from-file=cacerts.pem="${DIR}/cacerts.pem" \
  --dry-run=client -o yaml | oc apply -f -

# CMF's own Helm-based mTLS config (../flink/cmf-values.yaml) mounts these
# as Secrets (JKS format).
oc create secret generic cmf-keystore -n "$OPERATOR_NAMESPACE" \
  --from-file="${DIR}/cmf-keystore.jks" \
  --dry-run=client -o yaml | oc apply -f -
oc create secret generic cmf-truststore -n "$OPERATOR_NAMESPACE" \
  --from-file="${DIR}/cmf-truststore.jks" \
  --dry-run=client -o yaml | oc apply -f -

# Backing Secret for the FlinkSecret CR in ../flink/flink-resources.yaml;
# CFK syncs it to CMF for the Schema Registry catalog connection.
oc create secret generic flink-sr-tls -n "$OPERATOR_NAMESPACE" \
  --from-literal=schema.registry.security.protocol=SSL \
  --from-literal=schema.registry.ssl.truststore.type=PEM \
  --from-file=schema.registry.ssl.truststore.certificates="${DIR}/cacerts.pem" \
  --dry-run=client -o yaml | oc apply -f -

echo "Secrets created/updated in namespace ${NAMESPACE}: tls-kraftcontroller, tls-kafka, tls-controlcenter, connect-ca, sr-ssl-jks"
echo "Secrets created/updated in namespace ${OPERATOR_NAMESPACE}: cmf-day2-tls, cmf-keystore, cmf-truststore, flink-sr-tls"
