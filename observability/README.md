# Observability

Every signal goes to **Grafana Cloud**. Nothing is stored or queried in-cluster.

| Signal | Path | Lives in |
|--------|------|----------|
| GCP infra metrics | Cloud Monitoring → Grafana Alloy → `remote_write` | `observability/alloy/` |
| GCP billing | BigQuery → billing-exporter CronJob → OTLP | `k8s/billing-exporter/` |
| App traces, metrics, logs | `tasks` / `schedule` / `inbox` → OTel SDK → OTLP (`GRAFANA_OTLP_ENDPOINT`) | each service's own repo |
| Container logs (stdout) | GKE → Cloud Logging | cluster `logging_config` (API default) |

There is no in-cluster OpenTelemetry Collector and no self-hosted Grafana, Loki, Tempo or
Prometheus. They were removed in D1 (see `docs/specs/2026-09-10-cluster-cost-reduction-design.md`):
no service ever sent to the collector, and the stack behind it never served a query.

The only workload in the `observability` namespace is Alloy.

---

## Grafana Alloy (GCP infra metrics → Grafana Cloud)

Alloy scrapes GCP Cloud Monitoring (load balancing, Pub/Sub, Compute, Artifact Registry) and
`remote_write`s to Grafana Cloud Prometheus. It runs as a single-replica Deployment on a Spot node
and authenticates to GCP via Workload Identity (`alloy-gcp@bens-project-462804.iam.gserviceaccount.com`).

### Install / upgrade

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl apply -f observability/namespace.yaml

cp observability/alloy/secret.yaml.example observability/alloy/secret.yaml
# Edit secret.yaml — set Grafana Cloud Prometheus url / username / password
kubectl apply -f observability/alloy/secret.yaml

kubectl apply -f observability/alloy/configmap.yaml
helm upgrade --install alloy grafana/alloy \
  -n observability -f observability/alloy/values.yaml
```

`secret.yaml` is gitignored.

### Verify the resource requests landed

The chart key is `alloy.resources`; `controller.resources` does not exist and is silently ignored,
which leaves Autopilot's 500m/2Gi default in place. After every install or upgrade:

```bash
kubectl get pod -n observability -l app.kubernetes.io/name=alloy \
  -o jsonpath='{range .items[*].spec.containers[*]}{.name}{"\t"}{.resources.requests}{"\n"}{end}'
```

Expected: `alloy` at `100m` / `256Mi`, `config-reloader` at `10m` / `50Mi`.

### Changing what is scraped

`observability/alloy/config.alloy` is the readable source; `observability/alloy/configmap.yaml`
embeds the same config and is what is actually applied. Edit both, then:

```bash
kubectl apply -f observability/alloy/configmap.yaml
kubectl rollout restart deployment alloy -n observability
```

---

## billing-exporter (GCP billing → Grafana Cloud)

A CronJob in the `apps` namespace that queries the GCP billing export in BigQuery and pushes cost
metrics to Grafana Cloud via OTLP. Source is in `billing-exporter/`, manifests in
`k8s/billing-exporter/`, credentials in the `grafana-cloud-otlp` secret. It is independent of
everything in this directory.

---

## Application telemetry

Services instrument with the OpenTelemetry SDK and export OTLP straight to Grafana Cloud, configured
by `GRAFANA_OTLP_ENDPOINT` in each service. There is no node-local collector to route through, so do
not point anything at `localhost:4317` / `4318` or at an `observability` Service.

## Container logs

Stdout/stderr from every container goes to **Cloud Logging** via the cluster's `logging_config`
(`SYSTEM_COMPONENTS` + `WORKLOADS`). That is the only copy of container logs — see the
observability section of `CLAUDE.md` before changing it.

---

## Uninstall

```bash
helm uninstall alloy -n observability
kubectl delete -f observability/alloy/configmap.yaml
kubectl delete secret grafana-cloud-prometheus -n observability
kubectl delete -f observability/namespace.yaml
```
