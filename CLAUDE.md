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
observability/      LGTM stack (Loki, Grafana, Tempo, Prometheus) + OTel Collector
devbox/             Long-running workspace pod for experiments
```

## Namespaces

| Namespace | What lives there |
|-----------|-----------------|
| `apps` | All application workloads (inbox, blog, openclaw, postgres, redis) |
| `infra` | Shared Gateway, ReferenceGrant |
| `observability` | LGTM stack, OTel Collector |
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
- Images: `us-central1-docker.pkg.dev/bens-project-462804/<repo>/<image>:latest`
- Service accounts: annotate with `iam.gke.io/gcp-service-account` for Workload Identity

## Shared infrastructure

**Postgres** (`postgres.apps.svc.cluster.local:5432`): shared Postgres 16, namespace `apps`. Credentials in `postgres-credentials` k8s Secret. Do not create separate database instances for new workloads — add a new database to the existing instance instead.

**Redis** (`redis.apps.svc.cluster.local:6379`): shared Redis, namespace `apps`.

**Artifact Registry**: Docker repos at `us-central1-docker.pkg.dev/bens-project-462804/<repo-name>/`. Each workload has its own repo. Add new repos via `terraform/main.tf`.

## Observability

Apps instrument via the OpenTelemetry SDK (traces, metrics, logs). The OTel Collector DaemonSet receives OTLP on `localhost:4317` (gRPC) and `localhost:4318` (HTTP). Grafana is available at `grafana.drolet.cloud`.

> GKE Autopilot blocks `hostPath` and `hostNetwork` — stdout log tailing is not available. All signals must flow through the OTel SDK.

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
