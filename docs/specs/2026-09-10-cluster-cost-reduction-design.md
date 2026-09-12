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

- **`ntfy`** — an `e2-micro` Compute Engine VM with a reserved static IP
  and a 10 GB `pd-standard` disk, accounting for $6.02/month of the
  Compute Engine line. **This is live production infrastructure and is
  retained** — see D10. An earlier draft of this spec listed it as an
  orphan because it has no manifest in this repo. That was a misreading:
  it is not a Kubernetes workload, and it is owned by *inbox* Terraform
  (`inbox/terraform/ntfy.tf`), which is exactly why nothing defines it
  here. The variable comment in `cloudflare/ntfy.tf` says so directly.
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

**The `otel-collector` DaemonSet and `cluster-collector` go with it**
(4 pods, ~0.35 vCPU / 0.88 GiB). Nothing sends to them:

- No service targets them. `inbox`, `tasks`, `schedule` and
  `billing-exporter` all export to Grafana Cloud via
  `GRAFANA_OTLP_ENDPOINT`. There is not one reference to
  `otel-collector.observability.svc.cluster.local`, or to `localhost:4317`
  / `4318`, in any repo.
- No Kubernetes manifest sets an OTLP endpoint at all.
- The collector's three pipelines export exclusively into the stack this
  decision deletes — traces to Tempo, metrics to Prometheus, logs to Loki.
  Every destination disappears regardless.
- Tempo holds zero traces, corroborating the above from the other end.

`CLAUDE.md` describes a design in which apps instrument via the OTel SDK,
the DaemonSet receives OTLP on `localhost:4317`, and forwards to
self-hosted LGTM. **That wiring was never done.** Every service went
directly to Grafana Cloud instead, and the collector has run on every node
since receiving nothing — infrastructure built for an integration that
never happened, which is the same pattern as the rest of this namespace.

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

### D5 — Remove the superseded inbox path and dormant workloads

Delete `inbox-processor`, its KEDA `ScaledObject`, and KEDA itself. The
deployment has been dormant since 2026-06-01 and its trigger is erroring;
the work it did now runs in Cloud Functions against Cloud SQL.

Delete in-cluster `postgres` and `redis` with it. Both were part of the
same superseded design, and direct inspection confirms neither is in use:

- **Postgres** holds two databases totalling 8 MB. The `app` database has
  23 rows in `messages` and 17 in `senders`; `classifications`, `tags` and
  `message_embeddings` are empty and were never populated. The newest row
  in either table is **2026-06-01 17:11 UTC** — the same day
  `inbox-processor` last scaled. Nothing has written since. There are no
  client connections.
- **Redis** is empty: `DBSIZE` is 0, `INFO keyspace` lists no databases,
  and `keyspace_hits` and `keyspace_misses` are both **0** — it has never
  served a read. Its 4,479 processed commands against 4,480 connections
  are one-per-connection health-check pings. It has run for 168 days
  without storing a key.

Dump the 8 MB from Postgres to a file before deleting, as a cheap
insurance policy against the row counts meaning more than they appear to.
Redis needs no backup; there is nothing in it.

Two further workloads go with them, both confirmed with the owner on
2026-09-12:

- **`openclaw`** (250m/512Mi, plus a 5Gi PVC and a 627 MiB Artifact
  Registry repo) — no longer wanted. It has had no route to it since the
  Gateway was removed. Delete the Deployment, Service, PVC, `k8s/openclaw/`
  and the registry repo.
- **`devbox`** (Deployment 0/0 for 168 days) — the Deployment costs
  nothing at zero replicas, but `devbox-workspace` (10Gi) stays bound and
  billed. Delete the PVC; keep `devbox/` and `deploy/` in the repo so the
  workspace can be recreated on demand, which is how it was meant to be
  used.

With these, every PVC in the cluster is removed: `openclaw-data` (5Gi),
`postgres-data` (10Gi), `devbox-workspace` (10Gi), `grafana` (5Gi),
`prometheus-server` (20Gi), `storage-loki-0` (20Gi) and `storage-tempo-0`
(10Gi) — 80 GiB, the entire Balanced PD line.

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

Cloud Monitoring is the second-largest line, and the original draft of this
spec did not address it at all.

**The lever is Managed Prometheus, not the component list.** Per-SKU data
from the BigQuery billing export (last 30 days) splits the $43.71 as:

| SKU | Net |
|---|---|
| Prometheus Samples Ingested | **$41.33** |
| Time series billed count | $2.38 |

So `managed_prometheus { enabled = false }` is worth ~$41/month and
trimming `enable_components` is worth ~$2. An earlier draft of this
decision had that backwards. Someone executing it by trimming components
alone would see almost no change and reasonably conclude the analysis was
wrong — hence stating it explicitly.

Managed Prometheus has no user-defined scrape configs; its only
`ClusterPodMonitoring` resources are Google's own defaults, one of which
is a GPU exporter on a cluster with no GPUs.

Trim the component list as well — it is the same config block, costs
nothing to do, and removes metrics nothing reads. GKE's
`SYSTEM_COMPONENTS` metrics are free; the optional groups are not, and
this cluster has effectively all of them enabled:

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

### D9 — Narrow Secret Manager replication

Secret Manager is $10.37/month, and the per-SKU export identifies all of it
as **`Secret version replica storage`** — not access operations, as an
earlier draft of this spec assumed. Roughly 40 secret versions replicated
across regions under automatic replication account for the charge.

Move secrets to user-managed replication pinned to `us-central1`, and prune
superseded versions (several secrets carry 2–5 enabled versions where one
is current). Worth roughly $7/month.

Replication policy is fixed at creation time and cannot be changed in
place, so each secret must be recreated. Sequence this after the rest —
it touches live credentials for running services and carries more
operational risk than anything else in this plan for the least money.
Secrets are owned by several different Terraform states (see the
ownership note in the `tasks` repo), so this needs coordinating across
repos rather than being done here alone.

### D10 — Retain `ntfy`, and stop treating it as unowned

`ntfy` is live production infrastructure, not an orphan. It serves push
notifications for urgent inbox mail at `ntfy.drolet.ai`, with Let's
Encrypt TLS and an APNs relay for iOS delivery. The inbox Cloud Functions
consume it through `NTFY_BASE_URL` / `NTFY_TOPIC` / `NTFY_TOKEN`, and it
is referenced across `inbox/main.py`, `inbox/clients/ntfy.py`, the inbox
test suite, four Claude skills, and the `schedule` repo's RSVP-relay
design.

Critically, its notification **action buttons feed the label handler,
which publishes to the `inbox-labels` Pub/Sub topic — the source of the
`label_applied` events the `tasks` service consumes.** Deleting it would
break urgent-mail notification and a live input path into another
service.

It is owned by `inbox/terraform/ntfy.tf`. Nothing about it belongs in this
repo beyond the DNS record already in `cloudflare/ntfy.tf`, so no
migration is needed — only the correction that its absence from `k8s/` is
by design.

The general lesson, which cost this spec a wrong recommendation: *"not
defined in this repo"* is not evidence of *"unowned."* This project spans
several Terraform states, and a resource's home may be elsewhere. Check
the other repos before proposing a deletion.

## Open questions

**All resolved as of 2026-09-12.** Kept for the record.

- ~~**Q1 — Does anything send OTLP to the in-cluster collector?**~~
  **Resolved 2026-09-12: no.** Every service exports to Grafana Cloud; no
  repo or manifest references the collector. Folded into D1.
- ~~**Q2 — Is in-cluster `postgres` or `redis` still holding live data?**~~
  **Resolved 2026-09-12: no.** Postgres holds 8 MB frozen at 2026-06-01;
  Redis is empty and has never served a read. Folded into D5.
- ~~**Q3 — Is `ntfy` in use?**~~ **Resolved 2026-09-12: yes — retained.**
  See D10.
- ~~**Q4 — Is `openclaw` still wanted?**~~ **Resolved 2026-09-12: no.**
  Removed per owner decision; folded into D5.
- ~~**Q5 — Why is Secret Manager $65.70?**~~ **Resolved 2026-09-12:**
  replica storage under automatic replication, not access operations.
  Promoted to D9.

## Expected outcome

With every open question resolved, if D1–D5, D8 and D9 land:

| | Before | After |
|---|---|---|
| `observability` | 4.31 vCPU / 16.05 GiB, 12 pods | ~0.20 vCPU / 0.30 GiB, 1 pod (Alloy) |
| `keda` | 0.30 vCPU / 0.30 GiB, 3 pods | removed |
| PVCs | 90 GiB across 8 disks | ~25 GiB |
| Artifact Registry | 216 GiB | <10 GiB |
| Load balancers | 1 orphaned ALB | 0 |
| Cloud Monitoring components | 11 enabled + GMP + datapath | `SYSTEM_COMPONENTS` only |

Measured against the last 30 days of actual per-SKU spend, from the
BigQuery billing export
(`billing_export.gcp_billing_export_v1_*`, which covers 2026-04-01 onward):

| Service | Now | After | Saves | Covered by |
|---|---|---|---|---|
| Kubernetes Engine | $148.12 | ~$10 | ~$138 | D1, D2, D5 |
| Cloud Monitoring | $43.71 | ~$1 | ~$43 | D8 |
| Artifact Registry | $20.05 | ~$1 | ~$19 | D4 |
| Networking | $17.95 | ~$0 | ~$18 | D3 |
| Compute Engine | $13.83 | ~$6.5 | ~$7 | D5 (all PVCs); `ntfy` retained per D10 |
| Secret Manager | $10.37 | ~$3 | ~$7 | D9 |
| Cloud Run | $9.84 | $9.84 | — | retained |
| Cloud SQL | $9.19 | $9.19 | — | retained |
| Cloud Vision API | $5.05 | $5.05 | — | retained |
| **Total** | **$278.11** | **~$46** | **~$232** | |

Call it a reduction of **$215–245/month, landing at $35–60/month** —
comfortably below the $64/month flat line this was originally budgeted at.

What remains is `ntfy`, Cloud SQL, Cloud Run, Cloud Vision, a nearly-empty
Artifact Registry, and a cluster running only Alloy and the blog.

Every line above is a measured SKU total except the Kubernetes Engine
projection, which is apportioned by request share across the on-demand and
spot SKUs rather than read per-pod. Autopilot user-workload requests fall
from 5.54 vCPU to roughly 0.15 vCPU once D1, D5 and D8 land — a ~97%
reduction — but cost will not track that exactly: spot and on-demand pods
are removed in different proportions, and a floor remains from
Google-managed components and ephemeral storage. Treat ~$138 as a central
estimate with a band of roughly $105–150.

The residual cost is Cloud SQL, Cloud Run, the Cloud Functions, Grafana
Cloud egress, and a much smaller Artifact Registry — which is roughly what
this project should cost.

## Ordering

D6 first, alone — it is independent, reversible, and prevents recurrence
while the rest is in flight. Then D8, which is a single reversible field
and the largest saving per unit of risk. Then D2 (a prerequisite for Alloy
surviving D1 correctly), then D1, D4, D3, D5. D7 travels with whichever PR
changes the thing it documents.

D9 last, and separately — it is the smallest saving, it touches live
credentials, and it spans several Terraform states.

D8 must land with `loggingConfig` left intact, and D1 must not be applied
until that is confirmed — together they are the one ordering constraint in
this plan that can leave the cluster worse off.

## Measuring the result

A BigQuery billing export already exists —
`bens-project-462804.billing_export.gcp_billing_export_v1_*`, covering
2026-04-01 onward, and already queried by the `billing-exporter` CronJob.
It carries full SKU detail, so the effect of each decision can be measured
directly rather than estimated:

```sql
SELECT service.description, sku.description,
       ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount)
              FROM UNNEST(credits) c), 0)), 2) AS net
FROM `bens-project-462804.billing_export.gcp_billing_export_v1_*`
WHERE DATE(usage_start_time)
      BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
          AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
GROUP BY 1, 2 ORDER BY net DESC
```

Export rows lag actual usage by up to a day, so leave a day's gap before
reading a change's effect. Re-run this after each decision lands and
compare against the table above.
