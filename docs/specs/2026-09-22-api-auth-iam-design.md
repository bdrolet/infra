# API authentication: static bearer tokens → Cloud Run IAM — design

**Status:** proposed
**Date:** 2026-09-22
**Repos affected:** `tasks`, `people`, `inbox`, `docs`, `schedule`, `infra`

## Problem

Five Cloud Run services hold personal data — every task, contact, email,
document and calendar event:

| Service | Hostname | Repo |
|---|---|---|
| `tasks-api` | `tasks-api.drolet.cloud` | `tasks` |
| `people-api` | `people-api.drolet.cloud` | `people` |
| `inbox-api` | `inbox-api.drolet.cloud` | `inbox` |
| `docs-api` | `docs-api-aizbgjlava-uc.a.run.app` (no domain mapping) | `docs` |
| `schedule-api` | `schedule-api.drolet.cloud` | `schedule` |

All five are deployed the same way: `roles/run.invoker` granted to
`allUsers`, ingress open, and a single static bearer token checked in
application code (`api/auth.py`, or `_verify_token` in the two inbox
routers). Each token is minted once, stored in Secret Manager, and never
expires.

The token adds no strength beyond a Google identity — every caller
fetches it with `gcloud secrets versions access`, so anyone who can obtain
the token already holds a Google credential authorised on the project.
What it adds is exposure:

- **Copied to disk.** Each repo's `fetch-env.sh` writes the tokens into a
  local `.env`; three of them are also GitHub Actions secrets
  (`TF_VAR_TASKS_API_TOKEN`, `TF_VAR_DOCS_API_TOKEN`,
  `TF_VAR_SEARCH_TOKEN`).
- **Shared across callers.** The laptop skills, the `tasks` Cloud
  Functions and the `inbox` process function all present the same token
  to a given service. Nothing distinguishes them, and revoking one caller
  means rotating everyone.
- **Uneven enforcement.** `tasks`, `people`, `docs` and `schedule` use
  `secrets.compare_digest` and fail closed with 503 when the token is
  unset on Cloud Run. `inbox` compares with `!=` and returns *open* when
  `SEARCH_TOKEN` is unset.
- **Public front door.** Every request reaches the container before any
  check runs; the app absorbs scans and brute force alike.

## Goal

Authenticate every API caller with a Google identity at the Cloud Run
front door, using short-lived Google-signed ID tokens. Remove the static
tokens from Secret Manager, `.env` files and GitHub secrets. Keep the cost
at $0 — no load balancer, no IAP, no Cloudflare Access.

## Callers

Every current caller already has a Google identity:

| Caller | Identity | Calls |
|---|---|---|
| Claude Code skills and `scripts/test-api-local.py` on the laptop | `user:ben@drolet.cloud` (gcloud) | all five |
| `tasks-events-cf`, `tasks-webhook-cf` (via `services/triage.py`, `services/screening.py`) | SA `tasks-events-cf`, `tasks-webhook-cf` | `inbox-api` |
| `tasks-webhook-cf` (`handlers/due_digest.py`) | SA `tasks-webhook-cf` | `schedule-api` |
| `inbox-process-cf` (`handlers/pipeline.py` → `clients/people_api.py`) | SA `inbox-process-cf` | `people-api` |
| ntfy push notification tap on a phone | **none** | `inbox-api` `GET /r/{uuid}` |

The last row is the one exception and is handled by splitting the
redirector out (see below). No other anonymous caller exists: the
Cloudflare Terraform only holds DNS records, and the `*-d4` directories
are worktrees of the same repos.

## Design

### 1. Cloud Run IAM replaces the app-level check

Per service, in its own repo's Terraform:

- Delete the `google_cloud_run_v2_service_iam_member.api_public`
  (`allUsers`) binding.
- Grant `roles/run.invoker` on the service to each caller, one
  `google_cloud_run_v2_service_iam_member` per principal:

  | Service | Invokers |
  |---|---|
  | `tasks-api` | `user:ben@drolet.cloud` |
  | `people-api` | `user:ben@drolet.cloud`, SA `inbox-process-cf` |
  | `inbox-api` | `user:ben@drolet.cloud`, SA `tasks-events-cf`, SA `tasks-webhook-cf` |
  | `docs-api` | `user:ben@drolet.cloud` |
  | `schedule-api` | `user:ben@drolet.cloud`, SA `tasks-webhook-cf` |

  The user principal is a variable `api_invoker_users` (list, default
  `["ben@drolet.cloud"]`) so the binding is not hard-coded. Caller
  service accounts from other repos are resolved with
  `data "google_service_account"` by `account_id` — the same
  cross-repo pattern already used for `data.google_sql_database_instance`
  and `data.google_secret_manager_secret.shared`, and it avoids coupling
  Terraform states.
- Add `custom_audiences = ["https://<service>.drolet.cloud"]` on the
  `google_cloud_run_v2_service` for the four services with a domain
  mapping, so service-to-service callers can mint tokens for the hostname
  they already call. `docs-api` has no domain; its default audience (the
  `run.app` URL) is used as is. `gcloud run deploy` in the deploy
  workflows does not clear custom audiences or IAM, so the existing
  `ignore_changes = [image]` lifecycle stays sufficient.
- Keep `deployer_run_developer` unchanged.
- Ingress stays `INGRESS_TRAFFIC_ALL`. The laptop calls arrive from the
  public internet; IAM is the control, not the network.

Cloud Run's own startup and liveness probes do not go through IAM, so
`/health` continuing to exist is harmless, but external uptime checks (none
today) would need a credential.

### 2. Application code

In each of the five repos:

- Delete `api/auth.py` (inbox: the two `_verify_token` functions in
  `api/routers/search.py` and `api/routers/emails.py`) and every
  `dependencies=[Depends(verify_token)]` / `Security(_bearer)` reference.
- Delete the corresponding tests (`schedule/tests/test_api_auth.py`, the
  401 cases in `inbox/tests/test_emails_router.py`, and equivalents).
- Remove the `*_API_TOKEN` / `SEARCH_TOKEN` env var from the Cloud Run
  service in Terraform.
- Add one shared middleware, `api/caller.py`, that reads the
  `Authorization` header, base64-decodes the JWT payload **without
  verifying it** (Cloud Run has already verified the signature and
  audience before the request reached the container), and attaches
  `email` to the request log line:

  ```
  INFO api.caller GET /search 200 caller=ben@drolet.cloud
  INFO api.caller POST /search 200 caller=tasks-webhook-cf@bens-project-462804.iam.gserviceaccount.com
  ```

  This is the per-caller audit trail that IAM makes possible and the
  Cloud Run request log does not record on its own. A missing or
  undecodable header logs `caller=-` and does not reject the request;
  rejection is IAM's job, and doing it twice means two things to keep in
  sync. Off Cloud Run (`K_SERVICE` unset) the middleware is a no-op.

### 3. Callers

**Skills and scripts on the laptop.** Every skill that currently runs

```bash
TOKEN=$(gcloud secrets versions access latest --secret <name>-api-token --project bens-project-462804)
```

changes to

```bash
TOKEN=$(gcloud auth print-identity-token)
```

and keeps its `-H "Authorization: Bearer $TOKEN"` line as is. Cloud Run
accepts gcloud user ID tokens (audience: the gcloud OAuth client) for
any principal with `run.invoker`, regardless of custom audiences. The
token lasts one hour and nothing is written to disk.

Skills to update, by repo: `tasks` (`editing-tasks`, `fetching-task`,
`searching-tasks`), `people` (`editing-person`, `fetching-person`,
`searching-people`, `importing-linkedin`, `deploy-people`,
`verifying-pr-locally`), `inbox` (`fetching-inbox-email`,
`searching-inbox-emails`, `sending-inbox-email`,
`send-test-notification`, `verifying-pr-locally`), `docs` (`creating-doc`,
`editing-doc`, `fetching-doc`, `moving-doc`, `searching-docs`,
`uploading-doc`, `refreshing-msal-token`, `verifying-pr-locally`),
`schedule` (`editing-events`, `fetching-event`, `searching-events`).

`scripts/test-api-local.py` in each repo, and `docs/scripts/migrate_content.py`,
take the same path: when the base URL is not `localhost`, obtain the
token from `gcloud auth print-identity-token` instead of an env var.

**Python service-to-service clients.** A new module `clients/gcp_auth.py`
in `tasks` and `inbox`:

```python
def id_token_for(audience: str) -> str
```

- On Cloud Run / Cloud Functions (`K_SERVICE` set): `google.oauth2.id_token.fetch_id_token(Request(), audience)`, which reads the metadata server for the function's own service account. `google-auth` is already a dependency in both repos.
- Off Cloud Run: shell out to `gcloud auth print-identity-token`, so `due_digest` and the pipeline still run locally against the real APIs.
- Cache per audience and refresh once the token is within five minutes of its `exp`; ID tokens last one hour and the metadata server rate-limits.

The three clients change their header construction only:

| Client | Audience |
|---|---|
| `tasks/clients/schedule_api.py` | `SCHEDULE_API_URL` (`https://schedule-api.drolet.cloud`) |
| `tasks/clients/inbox_api.py` | `INBOX_API_URL` |
| `inbox/clients/people_api.py` | `PEOPLE_API_URL` (`https://people-api.drolet.cloud`) |

The audience **must equal the base URL the client calls**, and that URL
must be either the service's `run.app` URL or one of its
`custom_audiences`. `tasks` currently sets `inbox_api_url` to the
`run.app` URL in `terraform.tfvars`; it moves to
`https://inbox-api.drolet.cloud` so all three follow the same rule.

`SCHEDULE_API_TOKEN`, `INBOX_API_TOKEN` and `PEOPLE_API_TOKEN` are
removed from the Cloud Function `secret_environment_variables`, from
`fetch-env.sh`, from `.env.example`, and from `due_digest.py`'s
preflight check (which then requires only the URL).

### 4. `inbox-redirect`: the one public surface

`GET /r/{uuid}` on `inbox-api` resolves a message UUID to an Outlook
`webLink` and 302s to it. Its caller is a finger on a phone, via the
`click` URL of an ntfy push (`handlers/actions/urgent.py`,
`services/email_events.py` → `services/links.py`). It cannot carry a
Google credential and must stay anonymous. The UUID is the capability: a
bad one returns 404 before the database is touched, and the target is an
Outlook URL that requires its own login.

It moves into its own Cloud Run service so `inbox-api` can go IAM-only:

- `api/redirect_app.py`: a second FastAPI app that includes only
  `api/routers/redirect.py`. `api/main.py` stops including it.
- Same image (`inbox/inbox-api:latest`). Terraform
  `google_cloud_run_v2_service.redirect`, name `inbox-redirect`, with a
  container `command` override to `uvicorn api.redirect_app:app`.
  `max_instance_count = 2`, `timeout = "30s"`, `memory = "256Mi"`.
- Dedicated service account `inbox-redirect` with only what the route
  needs: `roles/cloudsql.client`, secret accessor on `inbox-db-password`,
  `msal-token-cache`, `client-id`, `client-secret`, `tenant-id`, and
  Artifact Registry reader. Env: `GCP_PROJECT_ID`,
  `CLOUD_SQL_CONNECTION_NAME`, `POSTGRES_USER`, `POSTGRES_DB`,
  `MSAL_SECRET_NAME`, plus the secret-backed `POSTGRES_PASSWORD`,
  `CLIENT_ID`, `CLIENT_SECRET`, `TENANT_ID`. No `SHARED_MAILBOXES`, no
  search or send capability.
- `roles/run.invoker` → `allUsers`, with a comment saying why this is the
  one service where that is correct.
- `REDIRECTOR_BASE_URL` on `inbox-process` changes from
  `google_cloud_run_v2_service.api.uri` to
  `google_cloud_run_v2_service.redirect.uri`. No domain mapping — the
  URL only ever appears inside a push payload.
- `deploy-api.yml` gains a second `gcloud run deploy inbox-redirect`
  step after the existing one; it deploys the same image.

Links inside push notifications already delivered point at the old
`inbox-api/r/...` path and will return 403 after the cutover. Push
notifications are ephemeral; this is accepted.

### 5. Secrets, variables and workflows removed

Once each service is cut over and verified:

| Repo | Remove |
|---|---|
| `tasks` | secret `tasks-api-token` (+ version, accessor binding), `variable "tasks_api_token"`, `TF_VAR_tasks_api_token` in `deploy.yml` and the GitHub secret, `INBOX_API_TOKEN`/`SCHEDULE_API_TOKEN` from function env and `fetch-env.sh` |
| `people` | secret `people-api-token` (+ accessor bindings), `PEOPLE_API_TOKEN` from `fetch-env.sh` |
| `inbox` | secret `search-token` (+ `search_cf_search_token` binding and the `tasks` accessor grant), `variable "search_token"`, `TF_VAR_search_token` in `deploy.yml` and the GitHub secret, `PEOPLE_API_TOKEN` from function env |
| `docs` | secret `docs-api-token` (+ version, accessor binding), `variable "docs_api_token"`, `TF_VAR_docs_api_token` in `deploy.yml` and the GitHub secret |
| `schedule` | secret `schedule-api-token`, `random_password.schedule_api_token`, accessor binding |

`terraform.tfvars` lines for the removed variables go with them. Local
`.env` files are regenerated by the trimmed `fetch-env.sh`.

## Migration order

The app-level check and IAM both read the same `Authorization` header, so
there is no state in which both work at once: either the service is
briefly public with no check, or briefly unreachable to callers still
sending the static token. The second is the only acceptable one. Each
service therefore cuts over in a fixed sequence, and the window between
steps 2 and 3 is minutes:

1. **Grant** — apply the invoker bindings and `custom_audiences`. The
   service is still public; nothing changes for callers.
2. **Close** — apply the removal of the `allUsers` binding. Every caller
   now gets 403 from IAM.
3. **Deploy** — run `deploy-api.yml` with the auth-free app and the
   caller middleware.
4. **Callers** — merge the skill and client changes; for cross-repo
   callers, deploy the calling function.
5. **Verify** (below), then **remove** the secret and variables in a
   final apply.

Steps 1–3 are one PR per repo (Terraform plus app), applied and deployed
in that order. Step 4 for cross-repo callers is a PR in the calling repo,
which must merge and deploy after the callee has closed.

Service order, chosen so the fewest callers are broken at each stage and
each service's callers are already converted before it closes:

| # | Service | Why here |
|---|---|---|
| 0 | `inbox` interim fix | Five-line change: `compare_digest` and fail-closed on Cloud Run. Lands now because `inbox-api` is last. |
| 1 | `people-api` | One skill set, one function caller (`inbox-process`). |
| 2 | `docs-api` | Laptop-only callers. |
| 3 | `schedule-api` | Laptop plus `tasks-webhook-cf`. |
| 4 | `tasks-api` | Laptop-only callers on the API itself; `clients/inbox_api.py` converts in the same PR. |
| 5 | `inbox-api` | Needs the `inbox-redirect` split first, then the cutover. `tasks` clients already converted in step 4. |

Two repos are touched as callers before their own cutover:

- `inbox` converts `clients/people_api.py` and ships `clients/gcp_auth.py`
  in step 1, before `people-api` closes; its own API cuts over in step 5.
- `tasks` converts `clients/schedule_api.py` and ships `clients/gcp_auth.py`
  in step 3, before `schedule-api` closes; `clients/inbox_api.py` converts
  in step 4 with its own cutover, ahead of `inbox-api` closing in step 5.

## Verification

Per service, after step 3:

```bash
SVC=people-api; URL=https://people-api.drolet.cloud
gcloud run services get-iam-policy $SVC --region us-central1 --project bens-project-462804   # no allUsers
curl -s -o /dev/null -w '%{http_code}\n' $URL/health                                          # 403
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(gcloud auth print-identity-token)" $URL/health   # 200
```

Then exercise the real callers: run one skill against the service; for
function callers trigger the path (`POST /digest` with `force` for
`tasks → schedule`, a test email through the pipeline for
`inbox → people`, a task-create for `tasks → inbox`) and confirm the
callee's log shows `caller=<function SA>` and no 403 in the caller's log.

For `inbox-redirect`: send a test notification (`send-test-notification`
skill), tap the link on the phone, land in Outlook.

Unit tests, per repo: `id_token_for` (metadata path mocked, gcloud
fallback mocked, cache expiry), the caller middleware (decodes a sample
JWT, tolerates a missing header, no-op off Cloud Run), and for `inbox`
that `api.redirect_app` imports and serves only `/r/{uuid}` while
`api.main` no longer routes it.

## Documentation

- Each repo's `CLAUDE.md` and `README.md` auth lines: "bearer token via
  `<name>-api-token`" becomes "Cloud Run IAM; callers send a Google ID
  token".
- `people/.claude/skills/adding-people-secret/SKILL.md` drops
  `people-api-token` from its list.
- `infra/CLAUDE.md`, networking option 2 (Cloud Run): add that APIs are
  IAM-authenticated, `run.invoker` is granted per caller, and `allUsers`
  is reserved for endpoints that a third party or a browser must reach
  anonymously — currently the webhook functions and `inbox-redirect`.

## Out of scope

- **Webhook Cloud Functions** (`tasks-webhook`, `inbox-webhook`,
  `schedule-webhook`, `people-sync`) stay public: Asana and Microsoft
  Graph cannot present Google credentials. They keep their HMAC and token
  checks.
- **Cloud Scheduler → `tasks-webhook` `/escalate` and `/digest`** keeps
  `ASANA_ESCALATE_TOKEN`. Moving those routes to a scheduler `oidc_token`
  (the pattern `inbox/terraform/scheduler.tf` already uses) is a natural
  follow-up but shares a function with Asana's anonymous posts, so it
  needs a route split first.
- **Cloudflare Access / IAP / Cloud Armor.** Each needs the proxied
  CNAME or a load balancer, which breaks the Cloud Run managed
  certificate or costs $18/month.
- **Rate limiting on `inbox-redirect`.** `max_instance_count = 2` bounds
  the blast radius; the UUID space makes enumeration impractical.

## Risks

- **A caller with no Google identity appears later** — a cloud Claude
  routine, a shortcut on a phone. It must use Workload Identity
  Federation or an ID token minted by something that has one. Service
  account keys are not an option; they recreate the static-secret problem
  with broader scope.
- **Audience mismatch** is the most likely cutover bug: a client minting
  for the `run.app` URL while calling the domain, or the reverse. The
  rule is one line — audience equals the base URL — and the 403 is
  immediate and visible in the callee's request log.
- **`gcloud run deploy` with `--allow-unauthenticated`** would silently
  reopen a service. None of the workflows pass it; the verification step
  checks the IAM policy, not the workflow file.
