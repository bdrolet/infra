# Cluster cost reduction — design

**Status:** proposed
**Date:** 2026-09-10

## Problem

GCP spend on `bens-project-462804` has climbed every month since the cluster
was created and shows no sign of levelling off:

| Period | Net cost |
|---|---|
| Mar 1 – Sep 30, 2026 | $1,054.84 |
| Sep 2026 (forecast) | $284.77 |

The curve starts at cluster creation (`bens-k8s`, 2026-03-24) — March was
~$13, April was the first month with a full cluster. Nothing is
mis-provisioned in an obvious way; the growth is the accumulated cost of
workloads that were stood up, superseded, and never torn down.

Breakdown for Mar–Sep, net of savings:

| Service | Cost | Share |
|---|---|---|
| Kubernetes Engine | $584.44 | 55% |
| Cloud Monitoring | $210.65 | 20% |
| Networking | $67.49 | 6% |
| Secret Manager | $65.70 | 6% |
| Artifact Registry | $48.27 | 5% |
| Compute Engine | $33.70 | 3% |
| Cloud SQL | $30.96 | 3% |
| Cloud Run | $8.03 | <1% |
| Cloud Vision API | $5.05 | <1% |
| Vertex AI | $0.34 | <1% |

All of it is `bens-project-462804`. The only other billed project is
`df-website-dev` at $0.02, so there is no second billing source to find.

## Current state

An audit of what is actually deployed, against what the repo describes.

### Autopilot request shares

Autopilot bills on pod **requests**, not usage. Excluding Google-managed
`kube-system`:

| Namespace | vCPU | GiB | pods |
|---|---|---|---|
| `observability` | 4.31 | 16.05 | 12 |
| `apps` | 0.80 | 1.56 | 4 |
| `keda` | 0.30 | 0.30 | 3 |
| `gke-managed-cim` | 0.11 | 0.13 | 1 |
| `gke-gmp-system` | 0.02 | 0.15 | 5 |

`observability` is 78% of billable CPU and 89% of billable memory — for a
cluster whose actual applications are a blog, a gateway, a Postgres and a
Redis.

### Root cause: unset resource requests

When a container declares no resources, Autopilot applies a default of
**500m CPU / 2 GiB memory**. Seven containers sit at exactly that:

| Container | Why it was missed |
|---|---|
| `tempo` | `resources:` is top-level in `observability/lgtm/tempo-values.yaml`; the chart reads `tempo.resources` |
| `alloy` | `resources:` is under `controller:` in `observability/alloy/values.yaml`; the chart reads `alloy.resources` |
| `kube-state-metrics` | subchart — `prometheus-values.yaml` sets only `nodeSelector` |
| `loki-sc-rules` | sidecar, no override |
| `loki-chunks-cache/exporter` | sidecar, no override |
| `loki-results-cache/exporter` | sidecar, no override |
| `prometheus-server-configmap-reload` | sidecar, no override |

That is **3.5 vCPU and 14 GiB — 81% of the namespace's CPU and 87% of its
memory** — consumed by containers nobody sized. The `values.yaml` files
carefully set 100m/256Mi on each *main* container, and those took effect;
everything around them did not.

### What is not being used

| Component | Evidence |
|---|---|
| Tempo | `GET /api/search/tags` returns `{"tagNames":[],"metrics":{}}` — zero traces, ever |
| Prometheus | `CrashLoopBackOff`, 56 restarts. Logs show WAL replay reaching segment 597 of 15,173 before being killed, then restarting from the beginning. It has never completed startup or served a query |
| Grafana | `observability.drolet.cloud` resolves to `8.233.220.63`, which is not a forwarding rule or reserved address in the project. The UI has been unreachable |
| `inbox-processor` | Scaled 0/0. Its KEDA `ScaledObject` reports `TriggerError`; last active **2026-06-01** |
| KEDA | `inbox-processor` is its only consumer |
| `devbox` | Deployment 0/0 for 168 days; `devbox-workspace` (10Gi) still bound and billed |

Loki could not be confirmed either way — it is a distroless image with no
shell, and `port-forward` would not establish during the audit. Its value
should be assumed low given that Grafana, the only way to read it, has been
unreachable.

### Architecture drift

The repo's `CLAUDE.md` states that the `infra` namespace owns a single
shared Gateway, and that standalone `Ingress` resources must never be
created because each spins up its own load balancer.

Neither is true in the cluster today:

- There is **no Gateway and no HTTPRoute** deployed.
- There **is** a standalone `Ingress` (`apps/blog`, 112 days old) serving
  `blog.drolet.cloud`, which created its own ALB — forwarding rules
  `k8s2-fr-8mckrdy9-apps-blog-b1bog1wm` and `k8s2-fs-…`, plus a reserved
  external IP.

The documented architecture and the running one have diverged. The rule in
`CLAUDE.md` was written to prevent exactly this and then was not followed.

### Resources outside the cluster

- **`ntfy`** — an `e2-micro` Compute Engine VM (created 2026-06-04,
  `RUNNING`) with a reserved static IP and a 10 GB `pd-standard` disk. It
  has no manifest in this repo; only its DNS record exists, in
  `cloudflare/ntfy.tf`. It accounts for the Compute Engine line.
- **Artifact Registry** — 216 GiB across 11 repos, **no cleanup policy on
  any of them**:

  | Repo | Size |
  |---|---|
  | `gcf-artifacts` | 155.2 GiB |
  | `inbox` | 58.7 GiB |
  | all others combined | ~4.6 GiB |

  `gcf-artifacts` is Cloud Functions build scratch, regenerated on every
  deploy; retained versions are waste.

- **Cloud SQL `inbox`** (`db-f1-micro`, Postgres 16) is `RUNNABLE` and is
  the live database. Per `~/src/inbox/docs/infrastructure-tradeoffs.md`,
  the pipeline moved from the in-cluster GKE Postgres path to Cloud
  Functions + Cloud SQL. The in-cluster `postgres` and `redis` are
  leftovers of the superseded design.

## Decisions

### D1 — Delete the self-hosted LGTM stack entirely

Not shrink it. Remove Grafana, Loki (and its two memcached caches), Tempo,
Prometheus, and kube-state-metrics, along with their five PVCs (55 GiB).

The stack has produced no observable value: Tempo holds zero traces,
Prometheus has never started, and Grafana has been unreachable. Meanwhile
Grafana Cloud already receives what is actually being read — GCP infra
metrics via Alloy, billing metrics via the `billing-exporter` CronJob, and
application telemetry from the `tasks` and `schedule` services, which ship
OTLP to Grafana Cloud directly and never used the in-cluster collector.

Keeping a second, broken observability plane while paying Grafana Cloud for
a working one is the single largest avoidable cost in the project.

**Retain:** Grafana Alloy and the `billing-exporter` CronJob — both write to
Grafana Cloud and are independent of the LGTM stack.

**Open:** the `otel-collector` DaemonSet (3 pods, 0.30 vCPU / 0.75 GiB) only
exports to Loki and Tempo. If nothing sends to it, it goes with them; see
Q1.

### D2 — Fix the resource-request nesting before anything else is redeployed

Move `resources:` to the key each chart actually reads — `tempo.resources`,
`alloy.resources` — verifying against `helm show values` rather than
assuming. Alloy survives D1, so this fix must land regardless.

Establish the rule in `CLAUDE.md` that every Helm-installed chart is
verified with `kubectl get pod -o …resources.requests` after install, since
a silently-ignored override is invisible in the values file.

### D3 — Reclaim orphaned networking

Delete the `apps/blog` Ingress and its ALB, and either redeploy the shared
Gateway from `k8s/infra/` or move the blog to Cloudflare Pages alongside the
`consulting` and `finances` sites. Given that the blog is a static Astro
build, Pages is the cheaper answer and removes the load balancer entirely.

Repoint or delete the dead `observability.drolet.cloud` A record in
`cloudflare/drolet-cloud.tf` — it references an IP that no longer exists.

### D4 — Add Artifact Registry cleanup policies

Add `cleanup_policies` to every repo in `terraform/main.tf`: keep the most
recent 3 tagged versions, delete untagged artifacts older than 7 days.
Applies to `gcf-artifacts` and `inbox` first, where the 216 GiB lives.

### D5 — Remove the superseded inbox path

Delete `inbox-processor`, its KEDA `ScaledObject`, and KEDA itself. The
deployment has been dormant since 2026-06-01 and its trigger is erroring;
the work it did now runs in Cloud Functions against Cloud SQL.

In-cluster `postgres` and `redis` are part of the same superseded design and
are the next candidates, but must not be deleted until Q2 is answered.

### D6 — Set a budget and alerts

There is no budget on the billing account and
`billingbudgets.googleapis.com` is not enabled. This is why a 20x increase
ran for six months unremarked.

Enable the API, then create a budget with alert thresholds at 50%, 90% and
100% of a monthly amount, plus a forecasted-spend alert. Manage it in
`terraform/` so it cannot be lost. This is the one change that should land
first — it is independent of everything else and prevents recurrence.

### D7 — Reconcile `CLAUDE.md` with reality

The Gateway rule, the observability description, and the cost notes all
describe a system that no longer exists. Update them in the same PR that
changes the cluster, so the document does not drift again.

### D8 — Trim GKE's Cloud Monitoring components

Cloud Monitoring is the second-largest line at $210.65 (20%), and the
original draft of this spec did not address it at all.

Cloud Monitoring bills on metric samples ingested. GKE's
`SYSTEM_COMPONENTS` metrics are free; the optional component groups are
not, and this cluster has effectively all of them enabled:

| Component | Collects | Decision |
|---|---|---|
| `SYSTEM_COMPONENTS` | control plane, node health | **keep** — free, powers the console cluster view |
| `CADVISOR`, `KUBELET` | per-container CPU/memory/disk, every scrape | **cut** — the high-cardinality pair, almost certainly most of the cost |
| `POD`, `DEPLOYMENT`, `DAEMONSET`, `STATEFULSET`, `HPA`, `STORAGE`, `JOBSET` | kube-state-style object metrics | **cut** — duplicates what Alloy already sends to Grafana Cloud |
| `DCGM` | NVIDIA GPU metrics | **cut** — there are no GPUs in this cluster; a managed `gke-managed-dcgm-exporter` scrape is running for hardware that does not exist |
| Managed Prometheus | a second Prometheus, billed per sample | **cut** — the only `ClusterPodMonitoring` resources are Google's own defaults; none are user-defined |
| Advanced Datapath Observability | eBPF network flow metrics | **cut** — only useful while debugging network policy |

Nothing consumes any of it. The project has **zero Cloud Monitoring
dashboards and zero alert policies** — the usual risk with this change is
silently breaking an alert that depends on a cut metric, and there are no
alerts to break.

```hcl
monitoring_config {
  enable_components = ["SYSTEM_COMPONENTS"]
  managed_prometheus { enabled = false }
  advanced_datapath_observability_config { enable_metrics = false }
}
```

**`loggingConfig` must not be touched.** It currently carries
`SYSTEM_COMPONENTS` + `WORKLOADS`, and once D1 removes Loki, Cloud Logging
becomes the only destination for container logs. Cutting both leaves the
cluster with no logs anywhere. Workload volume here is small enough to sit
inside the 50 GiB/month free tier.

This interaction is the reason D8 belongs in the spec rather than being
applied ad hoc: D1 and D8 are each safe alone and jointly remove every
place logs could land.

The change takes effect immediately, disrupts no pods, and is one field to
revert. Already-ingested data is retained under its existing retention
policy; only new ingestion stops.

## Open questions

- **Q1 — Does anything send OTLP to the in-cluster collector?** If nothing
  does, the `otel-collector` DaemonSet and `cluster-collector` go with D1.
  Resolve by checking the collector's `otelcol_receiver_accepted_*` counters
  before deletion.
- **Q2 — Is in-cluster `postgres` (pgvector, 10Gi) or `redis` still holding
  live data?** `~/src/inbox/clients/db.py` still *defaults* to
  `postgres.apps.svc.cluster.local`, though deployed callers override
  `POSTGRES_HOST`. Dump and verify before deleting either.
- **Q3 — Is `ntfy` in use?** It is a running VM with a static IP and a DNS
  record, but no manifest in this repo. If it is live it should be brought
  into the repo; if not, delete the VM, disk, IP and DNS record together.
- **Q4 — Is `openclaw` still wanted?** 250m/512Mi plus a 5Gi PVC, exposed
  only on a ClusterIP with no route to it since the Gateway was removed.
- **Q5 — Why is Secret Manager $65.70?** ~40 secret versions account for
  roughly $2.40/month; the rest is access operations, implying something
  reads secrets far more often than cold starts would explain. Worth its own
  investigation.

## Expected outcome

If D1–D5 and D8 land and Q1 resolves toward deletion:

| | Before | After |
|---|---|---|
| `observability` | 4.31 vCPU / 16.05 GiB, 12 pods | ~0.20 vCPU / 0.30 GiB, 1 pod (Alloy) |
| `keda` | 0.30 vCPU / 0.30 GiB, 3 pods | removed |
| PVCs | 90 GiB across 8 disks | ~25 GiB |
| Artifact Registry | 216 GiB | <10 GiB |
| Load balancers | 1 orphaned ALB | 0 |
| Cloud Monitoring components | 11 enabled + GMP + datapath | `SYSTEM_COMPONENTS` only |

Coverage against the Mar–Sep service mix:

| | Share | Covered by |
|---|---|---|
| Kubernetes Engine | 55% | D1, D2, D5 — most of it, since `observability` is 78% of billable CPU |
| Cloud Monitoring | 20% | D8 |
| Networking | 6% | D3 |
| Secret Manager | 6% | Q5 only — no decision yet |
| Artifact Registry | 5% | D4 |
| Compute Engine | 3% | Q3 (`ntfy`) — conditional |
| Cloud SQL, Cloud Run, Vision, Vertex | 4% | retained — the legitimate floor |

Estimated landing point of **$40–70/month** against a run rate forecasting
$284.77, leaving Secret Manager (Q5) as the only material line not yet
addressed. These are estimates reasoned from request shares, storage sizes
and enabled-component counts rather than a per-SKU bill; the per-SKU report
timed out during the audit, and a BigQuery billing export would make future
estimates exact.

The residual cost is Cloud SQL, Cloud Run, the Cloud Functions, Grafana
Cloud egress, and a much smaller Artifact Registry — which is roughly what
this project should cost.

## Ordering

D6 first, alone — it is independent, reversible, and prevents recurrence
while the rest is in flight. Then D8, which is a single reversible field
and the largest saving per unit of risk. Then D2 (a prerequisite for Alloy
surviving D1 correctly), then D1, D4, D3, D5. D7 travels with whichever PR
changes the thing it documents.

D8 must land with `loggingConfig` left intact, and D1 must not be applied
until that is confirmed — together they are the one ordering constraint in
this plan that can leave the cluster worse off.
