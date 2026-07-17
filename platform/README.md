# platform terraform

Neutral **platform** state for GCP resources shared across app repos. Owned here
so no single app repo can destroy or rename infrastructure another depends on.

State: `gs://bens-project-462804-tf-state`, prefix `platform` (separate from the
`terraform/` GKE root, which uses local state).

## What this state owns

| Resource | Consumed by |
|---|---|
| Secret `asana-api-key` | tasks (github.com/bdrolet/tasks) |
| Secret `grafana-otlp-endpoint` | inbox + tasks |
| Secret `grafana-otlp-token` | inbox + tasks |
| Secret `webhook-label-token` | inbox + tasks |
| Cloud SQL instance `inbox` (Postgres 16, `deletion_protection = true`) | inbox (db `app`) + tasks (db `tasks`) |

Consuming repos read these read-only via `data "google_secret_manager_secret"`
and `data "google_sql_database_instance"`. They resolve by name regardless of
which state owns the resource.

**Not owned here:** inbox's own secrets and its `app` database/`inbox` user
(inbox state); tasks' `tasks` database/user and its own secrets (tasks state);
`anthropic-api-key` (inbox-only) and `search-token` (inbox-api auth, inbox-owned).

## Applying

Secret values live in `terraform.tfvars` (gitignored — copy from
`terraform.tfvars.example`). ADC auth required (`gcloud auth application-default
login`).

```bash
cd platform
terraform init
terraform plan
terraform apply
```
