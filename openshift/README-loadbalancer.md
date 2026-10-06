# Deploying with a dedicated IP per component (LoadBalancer) instead of Routes

Alternative to [README.md](README.md) for customers who want each externally
reachable component on its own IP address instead of sharing the OpenShift
router (Routes, TLS passthrough on port 443). Only the steps below differ;
everything else in the main README (certs, secrets, Flink resources, cleanup)
is unchanged. This can be combined with
[README-internal-registry.md](README-internal-registry.md).

Not validated end to end. The CRD fields below were checked with
`oc explain` against CFK 3.3.0. The MetalLB, IP-pinning and CMF Service parts
have not been run.

## What changes

| Component | Routes (main README) | LoadBalancer (this file) |
|---|---|---|
| Kafka bootstrap | `kafka.<domain>:443` | `kafka.<domain>:9092` (own IP) |
| Kafka brokers | `b0..b2.<domain>:443` | `b0..b2.<domain>:9092` (one IP each) |
| Schema Registry | `https://schemaregistry.<domain>` | `https://schemaregistry.<domain>:8081` (own IP) |
| Control Center | `https://controlcenter.<domain>` | `https://controlcenter.<domain>:9021` (own IP) |
| CMF | `https://cmf.<domain>` (Route) | `https://cmf.<domain>` (own IP, new Service) |

That is 7 IPs for this deployment (4 for Kafka, 1 each for the others), plus
one more per extra broker. Everything inside the cluster (internal listener
`9071`, FKO, CMF, Connect, Flink) is unchanged.

Hostnames stay the same, so the certificate SANs from `generate-certs.sh`
(`kafka`, `b0..b2`, `schemaregistry`, `controlcenter`, `cmf`) still match.
Clients now connect straight to the IP, so the router and SNI routing are no
longer involved.

## 1. Prerequisites (new)

- **Bare metal / on-prem:** install the MetalLB Operator from OperatorHub (and
  create the `MetalLB` instance), then reserve addresses for the platform. The
  customer provides the address range:

  ```yaml
  apiVersion: metallb.io/v1beta1
  kind: IPAddressPool
  metadata:
    name: cp-pool
    namespace: metallb-system
  spec:
    addresses:
      - 192.168.10.20-192.168.10.30   # customer-provided range, at least 7 free IPs
    serviceAllocation:
      namespaces: [confluent, operator]
  ---
  apiVersion: metallb.io/v1beta1
  kind: L2Advertisement
  metadata:
    name: cp-l2
    namespace: metallb-system
  spec:
    ipAddressPools: [cp-pool]
  ```

  Use a `BGPAdvertisement` instead if the network is routed with BGP.
- **Cloud (ARO, ROSA, IBM Cloud...):** no MetalLB. The cloud provider creates
  one load balancer per Service, with its own address and cost. For internal
  load balancers add the provider's annotation under `annotations` below (for
  example `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`).
- **Network:** allow clients to reach TCP 9092, 8081, 9021 and 443 on those IPs.
- **DNS:** the Operator does not create DNS records. See step 4.

## 2. Edit `parameters.env`

```bash
export CFLT_OCP_ROUTE_DOMAIN=cp.example.com     # now just the DNS domain for the records below
export CFLT_KAFKA_EXTERNAL_BOOTSTRAP=kafka.${CFLT_OCP_ROUTE_DOMAIN}:9092
```

The variable keeps its `ROUTE` name only so no other file needs to change.
Pick a domain you can add records to; it does not have to be the cluster's
apps domain. If you change the domain, re-run `certs/generate-certs.sh` and
`certs/create-secrets.sh` (main steps 2 and 3).

## 3. Replace the Route blocks in `01-confluent-platform.yaml` (main step 4)

Replace the three `externalAccess` blocks, leaving the rest of the file as is.
Keep the edited file in a copy (for example `01-confluent-platform-lb.yaml`)
and apply that one with the same `envsubst` command.

**Kafka** (under `spec.listeners.external`):

```yaml
      externalAccess:
        type: loadBalancer
        loadBalancer:
          domain: ${CFLT_OCP_ROUTE_DOMAIN}
          bootstrapPrefix: kafka
          brokerPrefix: b
          # annotations: {}                  # for example MetalLB pool or cloud LB options
          # loadBalancerSourceRanges: []     # restrict which client networks can connect
```

**Schema Registry** (under `spec`):

```yaml
  externalAccess:
    type: loadBalancer
    loadBalancer:
      domain: ${CFLT_OCP_ROUTE_DOMAIN}
      port: 8081
```

**Control Center** (under `spec`):

```yaml
  externalAccess:
    type: loadBalancer
    loadBalancer:
      domain: ${CFLT_OCP_ROUTE_DOMAIN}
      port: 9021
```

Check the available fields on your CFK version with:

```bash
oc explain kafka.spec.listeners.external.externalAccess.loadBalancer --recursive
oc explain schemaregistry.spec.externalAccess.loadBalancer --recursive
oc explain controlcenter.spec.externalAccess.loadBalancer --recursive
```

The Kafka `loadBalancer.annotations` apply to all four Kafka Services, so they
cannot pin a different IP to each broker. Let MetalLB allocate from the pool
(step 1) and read the result in the next step.

## 4. DNS (new step, after the apply in main step 4)

Wait for the Services to get an address:

```bash
oc get svc -n confluent | grep LoadBalancer
```

Expect `kafka-bootstrap-lb`, `kafka-0-lb`, `kafka-1-lb`, `kafka-2-lb`,
`schemaregistry-bootstrap-lb` and `controlcenter-bootstrap-lb` (exact names
vary by CFK version). Create one A record per name pointing at its
`EXTERNAL-IP`:

| Record | Points to the IP of |
|---|---|
| `kafka.<domain>` | `kafka-bootstrap-lb` |
| `b0.<domain>`, `b1.<domain>`, `b2.<domain>` | `kafka-0-lb`, `kafka-1-lb`, `kafka-2-lb` |
| `schemaregistry.<domain>` | the Schema Registry Service |
| `controlcenter.<domain>` | the Control Center Service |
| `cmf.<domain>` | the CMF Service (step 6) |

For a local test with dnsmasq, replace the wildcard to the router with one
`address=/kafka.<domain>/<ip>` line per record.

If the customer needs fixed IPs, set the IP on each Service after it is
created (for MetalLB the annotation `metallb.universe.tf/loadBalancerIPs`; check
the annotation name for your MetalLB version) and confirm CFK does not revert
it on the next reconcile.

## 5. Verify (main step 5)

Same commands, with the new ports. `kafka-cli-commands.sh` already uses
`$CFLT_KAFKA_EXTERNAL_BOOTSTRAP`, so it picks up `:9092`. For Schema Registry:

```bash
curl --cacert certs/generated/cacerts.pem https://schemaregistry.${CFLT_OCP_ROUTE_DOMAIN}:8081/subjects
```

## 6. CMF (main step 6): replace the Route with a Service

Do not apply `flink/cmf-route.yaml`. The CMF chart only creates a ClusterIP
Service (`cmf-service`) and has no value to change its type, so add a separate
LoadBalancer Service for the same pod:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cmf-lb
  namespace: operator
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: confluent-manager-for-apache-flink
  ports:
    - name: https
      port: 443
      targetPort: 8080
```

Apply it with `oc apply -f`, then add the `cmf.<domain>` DNS record from step
4. The CMF certificate already includes `cmf.<domain>`. The Service forwards raw
TCP, so TLS and client-certificate handling behave as with the passthrough
Route.

## 7. Other differences

- **Main step 7 (Flink resources):** unchanged; they use in-cluster endpoints.
- **Scaling Kafka:** each added broker creates another LoadBalancer Service, so
  it needs one more IP and one more `b<N>.<domain>` DNS record (and a SAN in
  the Kafka certificate, or the existing `*.<domain>` wildcard).
- **Cleanup:** CFK removes its LoadBalancer Services with the custom
  resources. Also run `oc delete svc cmf-lb -n operator`, then remove the DNS
  records and the MetalLB pool if they are no longer needed.
