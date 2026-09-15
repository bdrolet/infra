# infra

Personal infrastructure repo. Manages a GKE Autopilot cluster and supporting GCP/Cloudflare resources.

## Cluster facts

| | |
|---|---|
| **GCP project** | `bens-project-462804` |
| **Cluster** | `bens-k8s`, GKE Autopilot, `us-central1` |
| **Domain** | `*.drolet.cloud` (wildcard TLS via GCP Certificate Manager) |
| **DNS / CDN** | Cloudflare |

## Repo layout

```
terraform/          GKE cluster + Artifact Registry (GCP)
cloudflare/         DNS, Cloudflare Pages projects
k8s/                Kubernetes manifests, one directory per workload
  infra/            Shared Gateway (owns the GCP load balancer — do not add more)
  inbox/            Inbox worker + KEDA ScaledObject
  blog/             Astro blog
  openclaw/         OpenClaw gateway
  postgres/         Shared Postgres 16 (namespace: apps)
  redis/            Redis (namespace: apps)
  billing-exporter/ CronJob: GCP billing (BigQuery) → OTLP metrics to Grafana Cloud
billing-exporter/   Python source + Dockerfile for the billing-exporter image
observability/      Self-hosted LGTM stack + OTel Collector; Grafana Alloy (GCP infra metrics → Grafana Cloud)
devbox/             Long-running workspace pod for experiments
```

## Namespaces

| Namespace | What lives there |
|-----------|-----------------|
| `apps` | All application workloads (inbox, blog, openclaw, postgres, redis, billing-exporter) |
| `infra` | Shared Gateway, ReferenceGrant |
| `observability` | Self-hosted LGTM stack, OTel Collector, Grafana Alloy |
| `devbox` | Devbox workspace pod |

## Local setup

```bash
gcloud auth application-default login
gcloud container clusters get-credentials bens-k8s --region us-central1 --project bens-project-462804
gcloud auth configure-docker us-central1-docker.pkg.dev
```

See `.claude/skills/gke-local-setup/SKILL.md` for a full checklist.

## Terraform

Two separate roots — apply each independently:

```bash
cd terraform   # GKE cluster + Artifact Registry
terraform init && terraform apply

cd cloudflare  # DNS + Cloudflare Pages
terraform init && terraform apply
```

State is stored locally (`terraform.tfstate`). Do not commit tfstate or `terraform.tfvars`.

## Applying manifests

Apply whole workload directories:

```bash
kubectl apply -f k8s/inbox/
kubectl apply -f k8s/blog/
```

Apply single files:

```bash
kubectl apply -f k8s/infra/gateway.yaml
```

Secrets are never committed. Each workload with secrets has a `secret.yaml.example`. Copy, fill in values, and apply:

```bash
cp k8s/<workload>/secret.yaml.example k8s/<workload>/secret.yaml
# edit secret.yaml
kubectl apply -f k8s/<workload>/secret.yaml
```

`secret.yaml` is gitignored cluster-wide.

## Networking: one Gateway, many routes

The `infra` namespace owns a single GCP Global External ALB via the Gateway API. All external traffic goes through it. **Do not create additional `LoadBalancer` Services or standalone `Ingress` resources** — that spins up a new GCP load balancer (~$18/month each).

To expose a new workload externally:
1. Add a `Service` (type: `ClusterIP`) in the `apps` namespace
2. Add an `HTTPRoute` that attaches to `shared-gateway` in `infra`
3. The wildcard TLS cert covers `*.drolet.cloud` automatically

Example:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: apps
spec:
  parentRefs:
    - name: shared-gateway
      namespace: infra
      sectionName: https
  hostnames:
    - my-app.drolet.cloud
  rules:
    - backendRefs:
        - name: my-app
          port: 8080
```

## Workload conventions

- Namespace: `apps` for all application workloads
- One subdirectory per workload under `k8s/`
- Resources: always set both `requests` and `limits` (Autopilot bills on requests)
- Helm charts: after every install or upgrade, verify the requests actually landed:

  ```bash
  kubectl get pod -n <ns> -l app.kubernetes.io/name=<chart> \
    -o jsonpath='{range .items[*].spec.containers[*]}{.name}{"\t"}{.resources.requests}{"\n"}{end}'
  ```

  A `resources:` block under the wrong key is silently ignored — the values file
  looks correct and Autopilot applies its 500m/2Gi default instead. Check the key
  against `helm show values <repo>/<chart>` before editing, and confirm against the
  running pod afterwards. The values file is not evidence.
- Images: `us-central1-docker.pkg.dev/bens-project-462804/<repo>/<image>:latest`
- Service accounts: annotate with `iam.gke.io/gcp-service-account` for Workload Identity

## Shared infrastructure

**Postgres** (`postgres.apps.svc.cluster.local:5432`): shared Postgres 16, namespace `apps`. Credentials in `postgres-credentials` k8s Secret. Do not create separate database instances for new workloads — add a new database to the existing instance instead.

**Redis** (`redis.apps.svc.cluster.local:6379`): shared Redis, namespace `apps`.

**Artifact Registry**: Docker repos at `us-central1-docker.pkg.dev/bens-project-462804/<repo-name>/`. Each workload has its own repo. Add new repos via `terraform/main.tf`.

## Observability

Two destinations, split by signal source:

**Self-hosted LGTM** (`observability/`) — app-level signals. Apps instrument via the OpenTelemetry SDK (traces, metrics, logs). The OTel Collector DaemonSet receives OTLP on `localhost:4317` (gRPC) and `localhost:4318` (HTTP) and forwards to the self-hosted LGTM stack. Grafana is at `observability.drolet.cloud`.

**Grafana Cloud** — infrastructure and billing signals the OTel Collector can't see:
- **Grafana Alloy** (`observability/alloy/`) scrapes GCP Cloud Monitoring (ALB, Pub/Sub, GKE, Artifact Registry) and `remote_write`s to Grafana Cloud Prometheus.
- **billing-exporter** (`k8s/billing-exporter/`) is a CronJob that queries GCP billing from BigQuery and pushes cost metrics to Grafana Cloud via OTLP.

> GKE Autopilot blocks `hostPath` and `hostNetwork` — stdout log tailing is not available. All app signals must flow through the OTel SDK.

## KEDA

KEDA is installed for event-driven autoscaling. The inbox worker uses it to scale from 0 to 1 based on Pub/Sub queue depth. Install via Helm if not already present:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

## Cost notes

- GKE Autopilot: free cluster management fee (covered by $74.40/month credit); pods billed per-second on resource requests
- GCP Global ALB: ~$18/month for the forwarding rule — shared across all routes
- Postgres pod (250m CPU, 512Mi, always-on): ~$10/month
- Scale pods to 0 when not in use; destroy with `terraform destroy` when done entirely
