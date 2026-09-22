# API auth: static bearer tokens → Cloud Run IAM — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every one of the five personal Cloud Run APIs (`people-api`, `docs-api`, `schedule-api`, `tasks-api`, `inbox-api`) rejects anonymous callers at the Cloud Run front door via IAM, callers present short-lived Google ID tokens, and the five static bearer tokens are deleted from Secret Manager, `.env` files and GitHub secrets.

**Architecture:** Per service, Terraform swaps the `allUsers` invoker for per-principal `roles/run.invoker` grants and adds `custom_audiences`; the app drops its `verify_token` dependency and gains a middleware that logs the authenticated caller. Laptop skills mint tokens with `gcloud auth print-identity-token`; the three Python service-to-service clients mint them from the metadata server through a shared `clients/gcp_auth.py`. `inbox-api`'s anonymous `/r/{uuid}` redirector moves to its own public Cloud Run service first, so `inbox-api` can close.

**Tech Stack:** Terraform (`hashicorp/google ~> 5.0`), FastAPI, `google-auth`, `httpx` (tasks) / `requests` (inbox), pytest, GitHub Actions with Workload Identity Federation.

**Spec:** `docs/specs/2026-09-22-api-auth-iam-design.md` (this repo, `~/src/infra`)

## Global Constraints

- Every repo: Python 3.13, `ruff` line length 100, tests run with `pytest tests/ -q`, lint with `ruff check . && ruff format --check .`.
- GCP project `bens-project-462804`, region `us-central1`.
- Never a state where a service is public with no app-level check. Per service the order is: **Terraform PR merged and applied (grants + close) → app PR merged and deployed → callers converted → cleanup PR**. Callers get 403 between the first two; that is accepted. The reverse order is not.
- Audience for a service-to-service call **equals the base URL the client calls**, and that URL is the service's `run.app` URL or one of its `custom_audiences`.
- `allUsers` on `roles/run.invoker` survives only on the webhook Cloud Functions and the new `inbox-redirect` service.
- Service account keys are never created. CI mints ID tokens through `google-github-actions/auth` with `token_format: id_token`.
- All five repos deploy Terraform from `.github/workflows/deploy.yml` on merge to `main`, and the API image from `deploy-api.yml` on merge when `api/**` or the Dockerfile changes. Two separate PRs per cutover keep those from racing.
- Commits and PRs end with the attribution lines the session provides.
- Never print a token value. The MSAL cache in `inbox/terraform/terraform.tfvars` is a secret; never `cat` that file.

---

## Cutover runbook (referenced by tasks below)

Used identically for each of the five services. `SVC` is the Cloud Run service name, `URL` its public base URL.

**R1 — Terraform PR.** Branch from `main`, make only the Terraform changes the task lists, run:

```bash
cd terraform && terraform init -input=false >/dev/null && terraform plan -input=false -out=/tmp/iam.plan
terraform show -no-color /tmp/iam.plan | grep -E '^\s*[#~+-] ' 
```

Expected: `+` for each new `google_cloud_run_v2_service_iam_member`, `-` for `api_public`, `~` on `google_cloud_run_v2_service.api` showing only `custom_audiences` (and the removed token `env` block where the task says so). Nothing else. Open the PR, merge it, wait for the `deploy.yml` run on `main` to go green.

**R2 — Confirm closed.**

```bash
gcloud run services get-iam-policy $SVC --region us-central1 --project bens-project-462804 --format=json | grep -c allUsers   # 0
curl -s -o /dev/null -w '%{http_code}\n' $URL/health                                                                        # 403
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(gcloud auth print-identity-token)" $URL/health          # 200 (old app still answers /health)
```

**R3 — App PR.** Branch from the updated `main`, make the app/skill/script/doc changes, run `ruff check . && ruff format --check . && pytest tests/ -q`, open the PR, merge, wait for `deploy-api.yml` on `main` to go green (its smoke step now authenticates as the deployer).

**R4 — Verify a real caller.** Run the repo's search skill once (or its `scripts/test-api-local.py --base $URL`) and confirm a 200. Then read the callee's log for the caller line:

```bash
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=$SVC AND textPayload:caller=" \
  --project bens-project-462804 --limit 5 --format='value(textPayload)'
```

Expected: lines ending in `caller=ben@drolet.cloud`.

**R5 — Cleanup PR.** Only after R4 and after every cross-repo caller of this service has been converted and deployed. Terraform will destroy the token secret; confirm the plan shows the secret, its version and its IAM bindings as `-` and nothing else unexpected.

---

## Appendix A — `api/caller.py` (verbatim, identical in all five repos)

```python
"""Log the authenticated caller on every request.

Cloud Run IAM has already verified the ID token's signature and audience
before the request reached the container. This decodes the payload only to
record who called; it never rejects a request — that is IAM's job, and doing
it twice means two things to keep in sync. Off Cloud Run (K_SERVICE unset)
nothing is installed."""

import base64
import json
import logging
import os

from fastapi import FastAPI, Request

logger = logging.getLogger(__name__)


def caller_email(authorization: str | None) -> str:
    """The `email` claim of a bearer JWT, or `-` when absent or undecodable."""
    if not authorization or not authorization.lower().startswith("bearer "):
        return "-"
    parts = authorization.split(" ", 1)[1].strip().split(".")
    if len(parts) != 3:
        return "-"
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except ValueError:  # binascii.Error, JSONDecodeError and UnicodeDecodeError all subclass it
        return "-"
    if not isinstance(claims, dict):
        return "-"
    return str(claims.get("email") or claims.get("sub") or "-")


def install(app: FastAPI) -> None:
    if not os.environ.get("K_SERVICE"):
        return

    @app.middleware("http")
    async def log_caller(request: Request, call_next):
        response = await call_next(request)
        logger.info(
            "%s %s %s caller=%s",
            request.method,
            request.url.path,
            response.status_code,
            caller_email(request.headers.get("authorization")),
        )
        return response
```

## Appendix B — `tests/test_caller.py` (verbatim, identical in all five repos)

```python
import base64
import json
import logging

from fastapi import FastAPI
from fastapi.testclient import TestClient

from api import caller


def _jwt(claims: dict) -> str:
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
    return f"hdr.{payload}.sig"


def test_caller_email_reads_email_claim():
    assert caller.caller_email(f"Bearer {_jwt({'email': 'a@b.c'})}") == "a@b.c"


def test_caller_email_falls_back_to_sub():
    assert caller.caller_email(f"Bearer {_jwt({'sub': '123'})}") == "123"


def test_caller_email_dash_when_missing_or_garbage():
    assert caller.caller_email(None) == "-"
    assert caller.caller_email("Basic abc") == "-"
    assert caller.caller_email("Bearer not-a-jwt") == "-"
    assert caller.caller_email("Bearer a.!!!.c") == "-"
    assert caller.caller_email(f"Bearer hdr.{base64.urlsafe_b64encode(b'[1]').decode()}.sig") == "-"


def test_install_is_noop_off_cloud_run(monkeypatch):
    monkeypatch.delenv("K_SERVICE", raising=False)
    app = FastAPI()
    caller.install(app)
    assert app.user_middleware == []


def test_install_logs_caller_on_cloud_run(monkeypatch, caplog):
    monkeypatch.setenv("K_SERVICE", "x-api")
    app = FastAPI()

    @app.get("/ping")
    def ping() -> dict:
        return {"ok": True}

    caller.install(app)
    with caplog.at_level(logging.INFO, logger="api.caller"):
        resp = TestClient(app).get("/ping", headers={"Authorization": f"Bearer {_jwt({'email': 'a@b.c'})}"})
    assert resp.status_code == 200
    assert "GET /ping 200 caller=a@b.c" in caplog.text
```

## Appendix C — `clients/gcp_auth.py` (verbatim, identical in `tasks` and `inbox`)

```python
"""Google-signed ID tokens for calling the other Cloud Run APIs.

On Cloud Run / Cloud Functions (K_SERVICE set) the metadata server mints a
token for this workload's own service account. Off it, gcloud's user
credential is used, so local runs hit the real APIs as the developer.
Tokens are cached per audience and refreshed five minutes before `exp`;
ID tokens last an hour and the metadata server rate-limits."""

import base64
import json
import os
import subprocess
import time

REFRESH_MARGIN_S = 300
_cache: dict[str, tuple[str, float]] = {}


def _exp(token: str) -> float:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return float(json.loads(base64.urlsafe_b64decode(payload))["exp"])


def _mint(audience: str) -> str:
    if os.environ.get("K_SERVICE"):
        import google.auth.transport.requests
        import google.oauth2.id_token

        request = google.auth.transport.requests.Request()
        return google.oauth2.id_token.fetch_id_token(request, audience)
    return subprocess.check_output(["gcloud", "auth", "print-identity-token"], text=True).strip()


def id_token_for(audience: str) -> str:
    """A bearer token accepted by the Cloud Run service whose URL is `audience`."""
    cached = _cache.get(audience)
    if cached and cached[1] - time.time() > REFRESH_MARGIN_S:
        return cached[0]
    token = _mint(audience)
    _cache[audience] = (token, _exp(token))
    return token


def reset_cache() -> None:
    _cache.clear()
```

## Appendix D — `tests/test_gcp_auth.py` (verbatim, identical in `tasks` and `inbox`)

```python
import base64
import json
import time

import pytest

from clients import gcp_auth


def _jwt(exp: float) -> str:
    payload = base64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).rstrip(b"=").decode()
    return f"hdr.{payload}.sig"


@pytest.fixture(autouse=True)
def _fresh_cache():
    gcp_auth.reset_cache()
    yield
    gcp_auth.reset_cache()


def test_mints_once_per_audience_while_fresh(monkeypatch):
    calls = []

    def fake_mint(aud):
        calls.append(aud)
        return _jwt(time.time() + 3600)

    monkeypatch.setattr(gcp_auth, "_mint", fake_mint)
    t1 = gcp_auth.id_token_for("https://a.example")
    t2 = gcp_auth.id_token_for("https://a.example")
    gcp_auth.id_token_for("https://b.example")
    assert t1 == t2
    assert calls == ["https://a.example", "https://b.example"]


def test_refreshes_inside_margin(monkeypatch):
    calls = []

    def fake_mint(aud):
        calls.append(aud)
        return _jwt(time.time() + gcp_auth.REFRESH_MARGIN_S - 1)

    monkeypatch.setattr(gcp_auth, "_mint", fake_mint)
    gcp_auth.id_token_for("https://a.example")
    gcp_auth.id_token_for("https://a.example")
    assert len(calls) == 2


def test_off_cloud_run_uses_gcloud(monkeypatch):
    monkeypatch.delenv("K_SERVICE", raising=False)
    seen = {}

    def fake_check_output(cmd, text):
        seen["cmd"] = cmd
        return "tok\n"

    monkeypatch.setattr(gcp_auth.subprocess, "check_output", fake_check_output)
    assert gcp_auth._mint("https://a.example") == "tok"
    assert seen["cmd"] == ["gcloud", "auth", "print-identity-token"]


def test_on_cloud_run_uses_metadata_server(monkeypatch):
    monkeypatch.setenv("K_SERVICE", "svc")
    import google.oauth2.id_token

    monkeypatch.setattr(google.oauth2.id_token, "fetch_id_token", lambda req, aud: f"tok-for-{aud}")
    assert gcp_auth._mint("https://a.example") == "tok-for-https://a.example"
```

## Appendix E — `scripts/test-api-local.py` token block (used by tasks, docs, people)

Replace the existing `token = os.environ.get("<X>_API_TOKEN")` block with:

```python
    # Local server: no auth. Deployed service: Cloud Run IAM wants a Google ID
    # token — CI passes one in API_ID_TOKEN (minted by google-github-actions/auth
    # as the deployer SA); a laptop mints its own via gcloud.
    headers = {}
    if not args.base.startswith(("http://localhost", "http://127.0.0.1")):
        token = os.environ.get("API_ID_TOKEN") or subprocess.check_output(
            ["gcloud", "auth", "print-identity-token"], text=True
        ).strip()
        headers["Authorization"] = f"Bearer {token}"
```

and add `import subprocess` to the imports.

## Appendix F — `deploy-api.yml` smoke step (tasks, docs, people)

Replace the existing `Smoke test deployed service` step with these two steps (keep the `actions/setup-python` step above them):

```yaml
      - name: Resolve service URL
        run: |
          echo "SERVICE_URL=$(gcloud run services describe SERVICE_NAME \
            --region us-central1 --project bens-project-462804 \
            --format='value(status.url)')" >> "$GITHUB_ENV"

      - id: id_token
        uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ secrets.GCP_WIF_PROVIDER }}
          service_account: ${{ secrets.GCP_DEPLOYER_SA }}
          token_format: id_token
          id_token_audience: ${{ env.SERVICE_URL }}
          id_token_include_email: true

      - name: Smoke test deployed service
        env:
          API_ID_TOKEN: ${{ steps.id_token.outputs.id_token }}
        run: |
          pip install httpx python-dotenv
          python scripts/test-api-local.py --base "$SERVICE_URL"
```

`SERVICE_NAME` is `tasks-api`, `docs-api` or `people-api`. `docs` and `inbox` pin `google-github-actions/auth@v2` elsewhere in the file; use the same major version the file already uses for the new step.

---

## Phase 0 — inbox interim hardening

### Task 1: inbox `_verify_token` constant-time and fail-closed

**Files:**
- Modify: `~/src/inbox/api/routers/search.py:14-22`
- Modify: `~/src/inbox/api/routers/emails.py:17-25`
- Test: `~/src/inbox/tests/test_api_auth_interim.py` (new)

**Interfaces:**
- Produces: nothing downstream; this whole file is deleted again in Task 13. It closes the fail-open gap for the weeks in between.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_api_auth_interim.py
import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from api.routers import emails, search


@pytest.mark.parametrize("verify", [search._verify_token, emails._verify_token])
def test_unset_token_on_cloud_run_fails_closed(monkeypatch, verify):
    monkeypatch.delenv("SEARCH_TOKEN", raising=False)
    monkeypatch.setenv("K_SERVICE", "inbox-api")
    with pytest.raises(HTTPException) as exc:
        verify(None)
    assert exc.value.status_code == 503


@pytest.mark.parametrize("verify", [search._verify_token, emails._verify_token])
def test_unset_token_off_cloud_run_is_open(monkeypatch, verify):
    monkeypatch.delenv("SEARCH_TOKEN", raising=False)
    monkeypatch.delenv("K_SERVICE", raising=False)
    assert verify(None) is None


@pytest.mark.parametrize("verify", [search._verify_token, emails._verify_token])
def test_wrong_token_is_401(monkeypatch, verify):
    monkeypatch.setenv("SEARCH_TOKEN", "s3cret")
    with pytest.raises(HTTPException) as exc:
        verify(HTTPAuthorizationCredentials(scheme="Bearer", credentials="nope"))
    assert exc.value.status_code == 401
```

- [ ] **Step 2: Run to verify the 503 cases fail**

Run: `cd ~/src/inbox && pytest tests/test_api_auth_interim.py -q`
Expected: 2 FAIL (`fails_closed` cases return None instead of raising), 4 PASS.

- [ ] **Step 3: Replace both `_verify_token` bodies**

In both files, replace the function with:

```python
def _verify_token(credentials: HTTPAuthorizationCredentials | None = Security(_bearer)) -> None:
    expected = os.environ.get("SEARCH_TOKEN")
    if not expected:
        if os.environ.get("K_SERVICE"):
            raise HTTPException(status_code=503, detail="service misconfigured: no auth token")
        return
    if credentials is None or not secrets.compare_digest(credentials.credentials, expected):
        raise HTTPException(status_code=401)
```

Add `import secrets` to both files' imports (stdlib group, after `import os`).

- [ ] **Step 4: Run the full suite**

Run: `cd ~/src/inbox && ruff check . && ruff format --check . && pytest tests/ -q`
Expected: all pass.

- [ ] **Step 5: Commit, PR, merge**

```bash
git checkout -b inbox-api-auth-interim
git add api/routers/search.py api/routers/emails.py tests/test_api_auth_interim.py
git commit -m "fix(api): constant-time token compare, fail closed on Cloud Run"
```

Open the PR, merge, let `deploy-api.yml` deploy.

---

## Phase 1 — `people-api`

### Task 2: people Terraform — grants, audience, close

**Files:**
- Modify: `~/src/people/terraform/api.tf:82-210`
- Modify: `~/src/people/terraform/variables.tf` (append)

**Interfaces:**
- Produces: `people-api` reachable only by `user:ben@drolet.cloud`, `inbox-process-cf@`, and the deployer SA; audience `https://people-api.drolet.cloud` accepted.

- [ ] **Step 1: Add the variable and data source**

Append to `terraform/variables.tf`:

```hcl
variable "api_invoker_users" {
  description = "Google accounts granted roles/run.invoker on people-api (laptop skills, scripts)"
  type        = list(string)
  default     = ["ben@drolet.cloud"]
}
```

In `terraform/api.tf`, directly above `resource "google_cloud_run_v2_service_iam_member" "api_public"`, add:

```hcl
# Callers of people-api. Cloud Run IAM is the only authentication: there is
# no app-level token. inbox-process looks up sender context at classify time
# (inbox/clients/people_api.py); its SA lives in inbox's terraform, so it is
# resolved by account id rather than by cross-state reference.
data "google_service_account" "inbox_process_cf" {
  account_id = "inbox-process-cf"
  project    = var.project_id
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_users" {
  for_each = toset(var.api_invoker_users)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "user:${each.value}"
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_inbox_process" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${data.google_service_account.inbox_process_cf.email}"
}

# deploy-api.yml's smoke test calls the deployed service as the deployer SA.
resource "google_cloud_run_v2_service_iam_member" "api_invoker_deployer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.deployer_sa}"
}
```

- [ ] **Step 2: Delete the `api_public` resource and its comment**

Remove lines `# Public — bearer-token auth enforced in app code (api/auth.py)` through the closing `}` of `resource "google_cloud_run_v2_service_iam_member" "api_public"`.

- [ ] **Step 3: Add `custom_audiences` and remove the token env**

Inside `resource "google_cloud_run_v2_service" "api"`, after `location = var.region`, add:

```hcl
  # Service-to-service callers mint ID tokens for the hostname they call.
  custom_audiences = ["https://people-api.drolet.cloud"]
```

Delete the whole `env { name = "PEOPLE_API_TOKEN" ... }` block (lines ~128-136).

- [ ] **Step 4: Plan, PR, merge, confirm — runbook R1 and R2**

`SVC=people-api URL=https://people-api.drolet.cloud`. Expected plan: `+3` IAM members (two `for_each` keys counted once each), `-1` `api_public`, `~1` service (audiences + env removal). Commit message: `feat(terraform): people-api authenticates with Cloud Run IAM`.

### Task 3: people app — drop `verify_token`, log caller, convert skills and smoke test

**Files:**
- Create: `~/src/people/api/caller.py` (Appendix A)
- Create: `~/src/people/tests/test_caller.py` (Appendix B)
- Delete: `~/src/people/api/auth.py`
- Modify: `~/src/people/api/main.py`, `api/routers/people.py:6,14`, `api/routers/search.py:4,10`, `api/routers/linkedin.py:9,13`
- Modify: `~/src/people/scripts/test-api-local.py`
- Modify: `~/src/people/.github/workflows/deploy-api.yml:52-60`
- Modify: skills `searching-people`, `fetching-person`, `editing-person`, `importing-linkedin`, `deploy-people`, `verifying-pr-locally`, `people-architecture` under `~/src/people/.claude/skills/`
- Modify: `~/src/people/CLAUDE.md:37,84`, `~/src/people/README.md:41,148-152`

- [ ] **Step 1: Write Appendix B to `tests/test_caller.py`, run it, see ImportError**

Run: `cd ~/src/people && pytest tests/test_caller.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'api.caller'`.

- [ ] **Step 2: Write Appendix A to `api/caller.py`; run again**

Expected: 5 PASS.

- [ ] **Step 3: Remove the auth dependency**

- `git rm api/auth.py`
- In `api/routers/people.py`, `search.py`, `linkedin.py`: delete `from api.auth import verify_token`, and change `router = APIRouter(dependencies=[Depends(verify_token)])` to `router = APIRouter()`. Remove `Depends` from the `fastapi` import if nothing else in the file uses it (`ruff check` will tell you).
- In `api/main.py`, after `app = FastAPI(title="people-api")`, add:

```python
from api import caller

caller.install(app)
```

(Import at top with the other `api` imports is fine too; keep ruff's isort happy.)

- [ ] **Step 4: Smoke script**

Rewrite `scripts/test-api-local.py`:

```python
#!/usr/bin/env python3
"""Smoke test people-api: --base URL. A deployed service needs a Google ID
token (API_ID_TOKEN, or gcloud's user credential); a local server needs none."""

import argparse
import os
import subprocess
import sys

import httpx

p = argparse.ArgumentParser()
p.add_argument("--base", default="http://127.0.0.1:8080")
args = p.parse_args()
h = {}
if not args.base.startswith(("http://localhost", "http://127.0.0.1")):
    token = os.environ.get("API_ID_TOKEN") or subprocess.check_output(
        ["gcloud", "auth", "print-identity-token"], text=True
    ).strip()
    h["Authorization"] = f"Bearer {token}"
r = httpx.get(f"{args.base}/health", headers=h, timeout=30)
assert r.status_code == 200, r.text
r = httpx.get(f"{args.base}/people?recent=1", headers=h, timeout=30)
assert r.status_code == 200, r.text
print("people-api smoke OK")
sys.exit(0)
```

- [ ] **Step 5: Deploy workflow smoke step — Appendix F with `SERVICE_NAME=people-api`**

The file uses `google-github-actions/auth@v3`. Remove the `PEOPLE_API_TOKEN: ${{ secrets.PEOPLE_API_TOKEN }}` env.

- [ ] **Step 6: Skills**

In `searching-people`, `fetching-person`, `editing-person`, `importing-linkedin` replace the line

```bash
TOKEN=$(gcloud secrets versions access latest --secret people-api-token --project bens-project-462804)
```

with

```bash
TOKEN=$(gcloud auth print-identity-token)   # Cloud Run IAM; your gcloud login is the credential
```

In `deploy-people/SKILL.md:53` replace `PEOPLE_API_TOKEN=$(gcloud secrets versions access latest --secret people-api-token) \` with nothing (the smoke script mints its own token); keep the `.venv/bin/python scripts/test-api-local.py --base "$API"` line.

In `verifying-pr-locally/SKILL.md:71` replace the sentence about `PEOPLE_API_TOKEN` with: "Auth is Cloud Run IAM, so a local server has no auth at all; requests need no header."

In `people-architecture/SKILL.md`: line 45 `──Bearer people-api-token──▶` becomes `──Google ID token (Cloud Run IAM)──▶`; line 59 `bearer auth via `people-api-token`` becomes `Cloud Run IAM (`roles/run.invoker` per caller, see terraform/api.tf)`; line 67 remove `people-api-token` from the owned list.

- [ ] **Step 7: Docs**

- `CLAUDE.md:37`: replace `bearer auth via `people-api-token`` with `auth is Cloud Run IAM — `roles/run.invoker` granted per caller in `terraform/api.tf`; callers send `gcloud auth print-identity-token``.
- `CLAUDE.md:84`: replace the `auth.py` line with `  caller.py                 logs the IAM-authenticated caller (email claim) per request; no-op off Cloud Run`.
- `README.md:41`: `bearer people-api-token` → `Google ID token`.
- `README.md:148-152`: drop the `PEOPLE_API_TOKEN=$(...) \` line.

- [ ] **Step 8: Lint, test, PR, merge, deploy, verify — runbook R3 and R4**

Run: `cd ~/src/people && ruff check . && ruff format --check . && pytest tests/ -q`. Commit message: `feat(api): Cloud Run IAM replaces the bearer token; log the caller`. After merge and deploy, run the `searching-people` skill once and check the log line per R4.

### Task 4: inbox as caller — `gcp_auth` and `people_api.py`

**Files:**
- Create: `~/src/inbox/clients/gcp_auth.py` (Appendix C), `~/src/inbox/tests/test_gcp_auth.py` (Appendix D)
- Modify: `~/src/inbox/clients/people_api.py:30-34`, `~/src/inbox/tests/test_people_api.py:21-24`
- Modify: `~/src/inbox/terraform/cloud_functions.tf:312-317`, `~/src/inbox/terraform/secrets.tf:75-80`
- Modify: `~/src/inbox/.env.example:45`, `~/src/inbox/CLAUDE.md:169`

**Interfaces:**
- Produces: `clients.gcp_auth.id_token_for(audience: str) -> str`, reused by nothing else in inbox yet.

- [ ] **Step 1: Appendix D → `tests/test_gcp_auth.py`; run; ImportError**

Run: `cd ~/src/inbox && pytest tests/test_gcp_auth.py -q` → FAIL on import.

- [ ] **Step 2: Appendix C → `clients/gcp_auth.py`; run → 4 PASS**

- [ ] **Step 3: Update the people client test first**

In `tests/test_people_api.py` change the `env` fixture to:

```python
@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("PEOPLE_API_URL", "https://people.example")
    monkeypatch.setattr(people_api.gcp_auth, "id_token_for", lambda aud: f"tok-for-{aud}")
```

and, in the test that inspects `seen["headers"]`, assert `seen["headers"]["Authorization"] == "Bearer tok-for-https://people.example"`. Run: `pytest tests/test_people_api.py -q` → FAIL (`people_api` has no attribute `gcp_auth`).

- [ ] **Step 4: Convert the client**

In `clients/people_api.py` add `from clients import gcp_auth` under `import clients.otel as otel`, and replace the `headers=` line with:

```python
            headers={"Authorization": f"Bearer {gcp_auth.id_token_for(base)}"},
```

Run: `pytest tests/test_people_api.py tests/test_gcp_auth.py -q` → PASS. Note `base` is already `PEOPLE_API_URL` stripped of a trailing slash, which is exactly the audience rule.

- [ ] **Step 5: Terraform and env**

- Delete the `secret_environment_variables { key = "PEOPLE_API_TOKEN" ... }` block from the `process` function in `terraform/cloud_functions.tf`.
- Delete `data "google_secret_manager_secret" "people_api_token"` and its comment from `terraform/secrets.tf`.
- Delete the `PEOPLE_API_TOKEN=` line from `.env.example`.
- `CLAUDE.md:169`: replace the `people-api-token` row with nothing; add to the row above or a note under the table: "`people-api` is called with a Google ID token minted by `clients/gcp_auth.py` for the `inbox-process-cf` SA — no secret."
- `terraform plan` must show only the `~` on the process function's env. `PEOPLE_API_URL` stays `https://people-api.drolet.cloud` in `terraform.tfvars` and the `PEOPLE_API_URL` GitHub variable.

- [ ] **Step 6: Lint, test, PR, merge**

Run: `ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat(people-api): call people-api with a Google ID token`. Merge; `deploy.yml` applies and redeploys the function.

- [ ] **Step 7: Verify inbox → people**

Send a test email through the pipeline (the `send-test-notification` skill or any real inbound mail), then:

```bash
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=people-api AND textPayload:"caller=inbox-process-cf@"' --project bens-project-462804 --limit 3 --format='value(textPayload)'
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=inbox-process AND textPayload:"people-api lookup failed"' --project bens-project-462804 --limit 3 --freshness=1h
```

Expected: at least one caller line; no lookup failures in the last hour.

### Task 5: people cleanup — delete `people-api-token`

**Files:**
- Modify: `~/src/people/terraform/secrets.tf:47-60`, `terraform/api.tf:51-55`, `terraform/iam.tf:55-62`, `terraform/variables.tf:36-40`
- Modify: `~/src/people/scripts/fetch-env.sh:30`, `.env.example:31`, `CLAUDE.md:203-218`, `.claude/skills/adding-people-secret/SKILL.md:44`

- [ ] **Step 1: Terraform**

Delete `random_password.people_api_token`, `google_secret_manager_secret.people_api_token`, `google_secret_manager_secret_version.people_api_token` (secrets.tf), `google_secret_manager_secret_iam_member.api_token` (api.tf), `google_secret_manager_secret_iam_member.inbox_process_api_token` and its comment (iam.tf), and `variable "inbox_process_sa"` (variables.tf; confirm with `grep -rn inbox_process_sa terraform/` that nothing else uses it).

- [ ] **Step 2: Files and docs**

- `scripts/fetch-env.sh`: delete the `PEOPLE_API_TOKEN=` line. `.env.example`: same.
- `CLAUDE.md:205`: `people-api-token, people-sync-token (all three` → `people-sync-token (both`. Delete the paragraph at 215-218 about granting `people-api-token` to inbox.
- `adding-people-secret/SKILL.md:44`: remove `people-api-token` from the list.

- [ ] **Step 3: Plan, PR, merge — runbook R5**

Expected plan: `-5` (password, secret, version, two bindings). Commit: `chore(terraform): delete people-api-token — Cloud Run IAM replaced it`. After apply: `gcloud secrets describe people-api-token --project bens-project-462804` → NOT_FOUND. Regenerate the local env: `scripts/fetch-env.sh`.

---

## Phase 2 — `docs-api`

### Task 6: docs Terraform — grants, close

**Files:**
- Modify: `~/src/docs/terraform/api.tf:75-185`, `terraform/variables.tf` (append)

- [ ] **Step 1: Variable and invokers**

Append to `variables.tf`:

```hcl
variable "api_invoker_users" {
  description = "Google accounts granted roles/run.invoker on docs-api (laptop skills, scripts)"
  type        = list(string)
  default     = ["ben@drolet.cloud"]
}
```

Replace the `# Public — bearer-token auth enforced in app code (api/auth.py)` comment and the `api_public` resource in `api.tf` with:

```hcl
# Callers of docs-api. Cloud Run IAM is the only authentication: there is no
# app-level token. docs-api has no domain mapping, so its run.app URL is the
# audience and no custom_audiences are needed.
resource "google_cloud_run_v2_service_iam_member" "api_invoker_users" {
  for_each = toset(var.api_invoker_users)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "user:${each.value}"
}

# deploy-api.yml's smoke test calls the deployed service as the deployer SA.
resource "google_cloud_run_v2_service_iam_member" "api_invoker_deployer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.deployer_sa}"
}
```

- [ ] **Step 2: Remove the token env**

Delete the `env { name = "DOCS_API_TOKEN" ... }` block from the service.

- [ ] **Step 3: Runbook R1, R2**

`SVC=docs-api URL=$(cd ~/src/docs/terraform && terraform output -raw docs_api_url)`. Expected plan: `+2`, `-1`, `~1`. Commit: `feat(terraform): docs-api authenticates with Cloud Run IAM`.

### Task 7: docs app — drop `verify_token`, log caller, convert skills, scripts, smoke test

**Files:**
- Create: `~/src/docs/api/caller.py` (Appendix A), `~/src/docs/tests/test_caller.py` (Appendix B)
- Delete: `~/src/docs/api/auth.py`
- Modify: `~/src/docs/api/main.py`, `api/routers/docs.py:12,21`, `api/routers/folders.py:7,11`, `api/routers/search.py:9,17`
- Modify: `~/src/docs/scripts/test-api-local.py:40-44`, `~/src/docs/scripts/migrate_content.py:72-79,158-159`
- Modify: `~/src/docs/.github/workflows/deploy-api.yml:56-64`
- Modify: skills `searching-docs`, `fetching-doc`, `creating-doc`, `editing-doc`, `moving-doc`, `uploading-doc`, `verifying-pr-locally` under `~/src/docs/.claude/skills/`
- Modify: `~/src/docs/CLAUDE.md:25,439-440`, `~/src/docs/scripts/fetch-env.sh:40-44`

- [ ] **Step 1: Appendix B → `tests/test_caller.py`; run; ImportError. Appendix A → `api/caller.py`; run; 5 PASS.**

- [ ] **Step 2: Remove the auth dependency**

`git rm api/auth.py`. In `api/routers/docs.py`, `folders.py`, `search.py`: delete the `from api.auth import verify_token` line and change `APIRouter(dependencies=[Depends(verify_token)])` to `APIRouter()`; drop `Depends` from the fastapi import where unused. In `api/main.py`, after `app = FastAPI(title="docs-api", lifespan=lifespan)`, add `caller.install(app)` with `from api import caller` among the imports.

- [ ] **Step 3: Scripts**

- `scripts/test-api-local.py`: Appendix E replaces the `headers = {}` … `headers["Authorization"] = ...` block; add `import subprocess`.
- `scripts/migrate_content.py`: replace `load_api_token()` (lines 72-79) with

```python
def load_api_token() -> str:
    """Google ID token for docs-api (Cloud Run IAM) from the gcloud user credential."""
    return subprocess.check_output(["gcloud", "auth", "print-identity-token"], text=True).strip()
```

add `import subprocess`, and remove `TFVARS_PATH` if nothing else uses it (`grep -n TFVARS_PATH scripts/migrate_content.py`).

- [ ] **Step 4: Deploy workflow — Appendix F with `SERVICE_NAME=docs-api`, `google-github-actions/auth@v2`**

Remove the `DOCS_API_TOKEN: ${{ secrets.TF_VAR_DOCS_API_TOKEN }}` env.

- [ ] **Step 5: Skills**

In `searching-docs`, `fetching-doc`, `creating-doc`, `editing-doc`, `moving-doc`, `uploading-doc` replace

```bash
TOKEN=$(grep 'docs_api_token' ~/src/docs/terraform/terraform.tfvars | grep -o '"[^"]*"' | tr -d '"')
```

with

```bash
TOKEN=$(gcloud auth print-identity-token)   # Cloud Run IAM; your gcloud login is the credential
```

`searching-docs/SKILL.md:38` "Never echo or commit the token value." stays true; keep it.

`verifying-pr-locally/SKILL.md:63,72-76`: line 63 drop `, DOCS_API_TOKEN`; replace 72-76 with "Auth is Cloud Run IAM, so a local server has no auth at all: `curl -s 'localhost:8080/search?q=report'`."

- [ ] **Step 6: Docs and fetch-env note**

- `CLAUDE.md:25`: `bearer auth via `docs-api-token` (env var `DOCS_API_TOKEN`)` → `auth is Cloud Run IAM — `roles/run.invoker` per caller in `terraform/api.tf`; callers send `gcloud auth print-identity-token``.
- `CLAUDE.md:439-440`: replace both lines with `# no auth locally — Cloud Run IAM is the only check, and it is not in the container` and `curl 'localhost:8080/search?q=report'`.
- `scripts/fetch-env.sh:40-44`: delete the four trailing comment/echo lines about enforced local auth.

- [ ] **Step 7: Runbook R3, R4**

Run: `cd ~/src/docs && ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat(api): Cloud Run IAM replaces the bearer token; log the caller`. Verify with the `searching-docs` skill.

### Task 8: docs cleanup — delete `docs-api-token`

**Files:**
- Modify: `~/src/docs/terraform/api.tf:17-29,48-52`, `terraform/variables.tf:18-22`, `terraform/terraform.tfvars:2`
- Modify: `~/src/docs/.github/workflows/deploy.yml:48`, `scripts/fetch-env.sh:26`, `.env.example:7`, `CLAUDE.md:421`

- [ ] **Step 1: Terraform** — delete `google_secret_manager_secret.docs_api_token`, its `_version`, `google_secret_manager_secret_iam_member.api_token`, `variable "docs_api_token"`, and the `docs_api_token = ...` line in `terraform.tfvars` (edit with `sed -i '' '/^docs_api_token/d' terraform/terraform.tfvars`; do not print the file).
- [ ] **Step 2: Workflow and env** — delete `TF_VAR_docs_api_token:` from `deploy.yml`; delete the `DOCS_API_TOKEN=` lines from `scripts/fetch-env.sh` and `.env.example`; delete the `docs-api-token` row from `CLAUDE.md`.
- [ ] **Step 3: Runbook R5** — expected plan `-3`. Commit: `chore(terraform): delete docs-api-token — Cloud Run IAM replaced it`. After merge: `gh secret delete TF_VAR_DOCS_API_TOKEN --repo bdrolet/docs`. Run `scripts/fetch-env.sh`.

---

## Phase 3 — `schedule-api`

### Task 9: tasks as caller of schedule — `gcp_auth` and `schedule_api.py`

**Files:**
- Create: `~/src/tasks/clients/gcp_auth.py` (Appendix C), `~/src/tasks/tests/test_gcp_auth.py` (Appendix D)
- Modify: `~/src/tasks/clients/schedule_api.py:28-29`, `~/src/tasks/handlers/due_digest.py:270-273`
- Modify: `~/src/tasks/tests/test_schedule_api.py:9-13`, `~/src/tasks/tests/test_due_digest_handler.py:100-104`
- Modify: `~/src/tasks/terraform/cloud_functions.tf:240-245`, `terraform/secrets.tf:19`, `terraform/iam.tf:9-16,60-70`
- Modify: `~/src/tasks/scripts/fetch-env.sh:26`, `~/src/tasks/CLAUDE.md:21`

**Interfaces:**
- Produces: `clients.gcp_auth.id_token_for(audience)`, reused by Task 12 for `inbox_api.py`.

- [ ] **Step 1: Appendix D → `tests/test_gcp_auth.py`; run; ImportError. Appendix C → `clients/gcp_auth.py`; run; 4 PASS.**

- [ ] **Step 2: Update the client tests first**

`tests/test_schedule_api.py` fixture:

```python
@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("SCHEDULE_API_URL", "https://sched.example")
    monkeypatch.setattr(sapi.gcp_auth, "id_token_for", lambda aud: f"tok-for-{aud}")
```

Any assertion on `seen["auth"]` becomes `== "Bearer tok-for-https://sched.example"`. `tests/test_due_digest_handler.py` `env` fixture: delete the `SCHEDULE_API_TOKEN` setenv line. Run both files → FAIL (`sapi` has no `gcp_auth`; digest preflight logs error).

- [ ] **Step 3: Convert the client and the preflight**

`clients/schedule_api.py`: add `from clients import gcp_auth` after `import httpx`, and:

```python
def _headers() -> dict:
    return {"Authorization": f"Bearer {gcp_auth.id_token_for(os.environ.get('SCHEDULE_API_URL', ''))}"}
```

`handlers/due_digest.py:270-271`:

```python
    if not os.environ.get("SCHEDULE_API_URL"):
        logger.error("SCHEDULE_API_URL unset — digest cannot run")
```

Run: `pytest tests/test_schedule_api.py tests/test_due_digest_handler.py tests/test_gcp_auth.py -q` → PASS.

- [ ] **Step 4: Terraform**

- `terraform/cloud_functions.tf`: delete the `secret_environment_variables { key = "SCHEDULE_API_TOKEN" ... }` block from the webhook function.
- `terraform/secrets.tf:19`: delete `"schedule-api-token", # ...` from the `shared` set.
- `terraform/iam.tf`: in `events_cf_shared` remove the `if k != "schedule-api-token"` filter (the key no longer exists; the `for` becomes `{ for k, v in data.google_secret_manager_secret.shared : k => v }`) and delete the two comment lines above it about schedule-api-token. In the comment above `webhook_cf_shared` delete the sentence "This is also where the webhook CF's read access to schedule-api-token comes from … in the shared set."
- `scripts/fetch-env.sh`: delete `SCHEDULE_API_TOKEN=$(secret schedule-api-token)`.
- `CLAUDE.md:21`: `(`SCHEDULE_API_URL`/`SCHEDULE_API_TOKEN`, secret owned by schedule terraform)` → `(`SCHEDULE_API_URL`; auth is a Google ID token for the `tasks-webhook-cf` SA via `clients/gcp_auth.py`)`.

`terraform plan` expected: `~` webhook function env, `-` the two `secretAccessor` bindings on `schedule-api-token` (events + webhook `for_each` keys). Nothing else.

- [ ] **Step 5: Lint, test, PR, merge**

Run: `cd ~/src/tasks && ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat(schedule-api): call schedule-api with a Google ID token`. Merge; `deploy.yml` applies and redeploys the functions. Until Task 10 closes `schedule-api`, the digest sends an ID token to a public service that still expects its static token → 401 → the digest logs an error every 10 minutes. Proceed to Task 10 immediately.

### Task 10: schedule Terraform — grants, audience, close

**Files:**
- Modify: `~/src/schedule/terraform/api.tf:91-221`, `terraform/variables.tf` (append)

- [ ] **Step 1: Variable, data source, invokers**

Append to `variables.tf`:

```hcl
variable "api_invoker_users" {
  description = "Google accounts granted roles/run.invoker on schedule-api (laptop skills, scripts)"
  type        = list(string)
  default     = ["ben@drolet.cloud"]
}
```

Replace the `# Public ingress; authentication is the app-level bearer token, as tasks-api does.` comment and the `api_public` resource with (this file's style omits `project`):

```hcl
# Callers of schedule-api. Cloud Run IAM is the only authentication: there is
# no app-level token. tasks' webhook CF writes the due-day digest
# (tasks/clients/schedule_api.py); its SA lives in tasks' terraform, so it is
# resolved by account id.
data "google_service_account" "tasks_webhook_cf" {
  account_id = "tasks-webhook-cf"
  project    = var.project_id
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_users" {
  for_each = toset(var.api_invoker_users)
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "user:${each.value}"
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_tasks_webhook" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${data.google_service_account.tasks_webhook_cf.email}"
}
```

- [ ] **Step 2: Audience and env**

In `resource "google_cloud_run_v2_service" "api"` after `location = var.region` add `custom_audiences = ["https://schedule-api.drolet.cloud"]` with the same comment as Task 2. Delete the `env { name = "SCHEDULE_API_TOKEN" ... }` block.

- [ ] **Step 3: Runbook R1, R2**

`SVC=schedule-api URL=https://schedule-api.drolet.cloud`. Expected plan `+2`, `-1`, `~1`. Commit: `feat(terraform): schedule-api authenticates with Cloud Run IAM`.

### Task 11: schedule app — drop `verify_token`, log caller, docs

**Files:**
- Create: `~/src/schedule/api/caller.py` (Appendix A), `~/src/schedule/tests/test_caller.py` (Appendix B)
- Delete: `~/src/schedule/api/auth.py`, `~/src/schedule/tests/test_api_auth.py`
- Modify: `~/src/schedule/api/main.py`, `api/routers/search.py:9,90`, `freebusy.py:10,172`, `calendars.py:4,28`, `events.py:10,142,298,409,496,536`
- Modify: `~/src/schedule/scripts/test-api-local.py:55-77`, `~/src/schedule/docs/calendar-api-conventions.md:13`
- Modify: `~/src/schedule/CLAUDE.md:39,105,194-195`, `~/src/schedule/README.md:90-95`

- [ ] **Step 1: Appendix B → `tests/test_caller.py`; ImportError. Appendix A → `api/caller.py`; 5 PASS.**

- [ ] **Step 2: Remove the auth dependency**

`git rm api/auth.py tests/test_api_auth.py`. In the four routers delete `from api.auth import verify_token` and every `_: None = Depends(verify_token)` parameter (with its preceding comma). Where a signature becomes `def get_calendars() -> CalendarsResponse:` that is correct. Drop unused `Depends` imports. In `api/main.py` after `app = FastAPI(title="schedule-api")` add `caller.install(app)` (`from api import caller`). Keep a health test: add to `tests/test_caller.py`

```python
def test_health_needs_no_token():
    from api.main import app

    assert TestClient(app).get("/health").json() == {"status": "ok"}
```

- [ ] **Step 3: Smoke script**

In `scripts/test-api-local.py` replace the `token = (os.environ.get("SCHEDULE_API_TOKEN") or subprocess.check_output([...tfvars...]))` expression (lines 63-72) with:

```python
    token = os.environ.get("API_ID_TOKEN") or subprocess.check_output(
        ["gcloud", "auth", "print-identity-token"], text=True
    ).strip()
```

Update the docstring line `scripts/test-api-local.py --url http://localhost:8081 --write` to note a local server ignores the token.

- [ ] **Step 4: Skill conventions and docs**

- `docs/calendar-api-conventions.md:13`: `TOKEN=$(gcloud auth print-identity-token)   # Cloud Run IAM; your gcloud login is the credential`.
- `CLAUDE.md:39`: `bearer auth via `schedule-api-token`` → `auth is Cloud Run IAM — `roles/run.invoker` per caller in `terraform/api.tf``.
- `CLAUDE.md:105`: `auth.py …` → `caller.py                 logs the IAM-authenticated caller (email claim) per request; no-op off Cloud Run`.
- `CLAUDE.md:194-195`: delete the `SCHEDULE_API_TOKEN` sentence (`API-only:` now starts with `CALENDAR_LIST_TTL`).
- `README.md:90-95`: replace from `every route except /health requires` to `the same shape as tasks-api.` with: `Cloud Run IAM authenticates every request (`roles/run.invoker` granted to Ben's account and to `tasks-webhook-cf@`); callers send a Google ID token, `gcloud auth print-identity-token` from a laptop. Nothing in the app checks credentials.`

- [ ] **Step 5: Runbook R3, R4**

Run: `cd ~/src/schedule && ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat(api): Cloud Run IAM replaces the bearer token; log the caller`. Verify with `searching-events`, then force a digest and check for the function caller:

```bash
TOK=$(gcloud secrets versions access latest --secret tasks-escalate-token --project bens-project-462804)
curl -s -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"force":true}' "$(cd ~/src/tasks/terraform && terraform output -raw webhook_url)/digest"
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=schedule-api AND textPayload:"caller=tasks-webhook-cf@"' --project bens-project-462804 --limit 3 --format='value(textPayload)'
```

(If `webhook_url` is not an output, use `gcloud functions describe tasks-webhook --region us-central1 --format='value(serviceConfig.uri)'`.)

### Task 12: schedule cleanup — delete `schedule-api-token`

**Files:**
- Modify: `~/src/schedule/terraform/api.tf:23-46,72-76`, `scripts/fetch-env.sh:28`, `CLAUDE.md:327-330,524-525`

- [ ] **Step 1:** Delete `google_secret_manager_secret.schedule_api_token`, the `random_password` with its long comment, the `_version`, and `google_secret_manager_secret_iam_member.api_token`. Delete the `SCHEDULE_API_TOKEN=` line in `fetch-env.sh`. `CLAUDE.md:327`: remove `, `schedule-api-token`` and the parenthetical; `Those last three` → `Those last two`. `CLAUDE.md:524-525`: delete `The bearer token needs no setup — … secret:`.
- [ ] **Step 2: Runbook R5** — expected plan `-4`. Commit: `chore(terraform): delete schedule-api-token — Cloud Run IAM replaced it`. Run `scripts/fetch-env.sh`.

---

## Phase 4 — `tasks-api`

### Task 13: tasks Terraform — grants, close, inbox audience

**Files:**
- Modify: `~/src/tasks/terraform/api.tf:89-197`, `terraform/variables.tf` (append; `inbox_api_url` description), `terraform/terraform.tfvars:16`

- [ ] **Step 1: Variable and invokers**

Append to `variables.tf`:

```hcl
variable "api_invoker_users" {
  description = "Google accounts granted roles/run.invoker on tasks-api (laptop skills, scripts)"
  type        = list(string)
  default     = ["ben@drolet.cloud"]
}
```

Replace the `# Public — bearer-token auth enforced in app code (api/auth.py)` comment and `api_public` with:

```hcl
# Callers of tasks-api. Cloud Run IAM is the only authentication: there is no
# app-level token. Only the laptop and the deploy smoke test call it.
resource "google_cloud_run_v2_service_iam_member" "api_invoker_users" {
  for_each = toset(var.api_invoker_users)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "user:${each.value}"
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_deployer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.deployer_sa}"
}
```

- [ ] **Step 2: Audience, env, inbox URL**

In the service add `custom_audiences = ["https://tasks-api.drolet.cloud"]`; delete the `env { name = "TASKS_API_TOKEN" ... }` block. In `terraform.tfvars` set `inbox_api_url = "https://inbox-api.drolet.cloud"` (so `clients/inbox_api.py`'s audience is a custom audience Task 16 grants) and update the `inbox_api_url` variable description to `inbox-api base URL and ID-token audience — must be https://inbox-api.drolet.cloud, one of inbox-api's custom_audiences`. Update the GitHub variable too: `gh variable set INBOX_API_URL --repo bdrolet/tasks --body https://inbox-api.drolet.cloud`.

- [ ] **Step 3: Runbook R1, R2**

`SVC=tasks-api URL=https://tasks-api.drolet.cloud`. Expected plan `+2`, `-1`, `~1` service, `~` on the events and webhook functions (`INBOX_API_URL` env). Commit: `feat(terraform): tasks-api authenticates with Cloud Run IAM`.

### Task 14: tasks app — drop `verify_token`, log caller, convert `inbox_api.py`, skills, smoke test

**Files:**
- Create: `~/src/tasks/api/caller.py` (Appendix A), `~/src/tasks/tests/test_caller.py` (Appendix B)
- Delete: `~/src/tasks/api/auth.py`
- Modify: `~/src/tasks/api/main.py`, `api/routers/projects.py:5,47,64,72`, `tasks.py:7,198,257,294`, `search.py:9,153`, `comments.py:5,26,34,42`
- Modify: `~/src/tasks/tests/test_api_main.py:16-59`, `tests/test_api_comments.py:14`, `tests/test_api_tasks.py:14`, `tests/test_api_projects.py:13`, `tests/test_api_search.py:14`
- Modify: `~/src/tasks/clients/inbox_api.py:14,25,54`, `tests/test_inbox_api.py:18-27`
- Modify: `~/src/tasks/terraform/cloud_functions.tf:161-166`, `terraform/secrets.tf:17`, `scripts/fetch-env.sh:24`
- Modify: `~/src/tasks/scripts/test-api-local.py:29-32`, `.github/workflows/deploy-api.yml:52-60`
- Modify: skills `searching-tasks:25`, `editing-tasks:19`, `fetching-task:28`, `verifying-pr-locally:79-80` under `~/src/tasks/.claude/skills/`
- Modify: `~/src/tasks/CLAUDE.md:19`, `~/src/tasks/README.md:146-148`

- [ ] **Step 1: Appendix B → `tests/test_caller.py`; ImportError. Appendix A → `api/caller.py`; 5 PASS.**

- [ ] **Step 2: Remove the auth dependency**

`git rm api/auth.py`. In the four routers delete the `verify_token` import and every `_: None = Depends(verify_token)` parameter; drop unused `Depends`. In `api/main.py` after `app = FastAPI(title="tasks-api")` add `caller.install(app)`. In `tests/test_api_main.py` delete the five `test_verify_token_*` functions (lines 16-59) and any now-unused imports. In the four `tests/test_api_*.py` fixtures delete the `monkeypatch.setenv("TASKS_API_TOKEN", "sekrit")` line and any `Authorization` header the tests send (grep `Bearer sekrit`), since nothing checks it now.

- [ ] **Step 3: `inbox_api.py` test first**

`tests/test_inbox_api.py` fixture:

```python
@pytest.fixture(autouse=True)
def configure(monkeypatch):
    monkeypatch.setattr(inbox_api, "INBOX_API_URL", "https://inbox-api.example")
    monkeypatch.setattr(inbox_api.gcp_auth, "id_token_for", lambda aud: f"tok-for-{aud}")
```

and `test_get_email_hits_endpoint_with_bearer` asserts `== "Bearer tok-for-https://inbox-api.example"`. Run → FAIL.

- [ ] **Step 4: Convert `inbox_api.py`**

Delete `INBOX_API_TOKEN = ...`; add `from clients import gcp_auth`; add

```python
def _headers() -> dict:
    return {"Authorization": f"Bearer {gcp_auth.id_token_for(INBOX_API_URL)}"}
```

and use `headers=_headers()` in both `_get` and `search`. Update the module docstring's "bearer-authed HTTP interface" to "IAM-authenticated HTTP interface (Google ID token, `clients/gcp_auth.py`)". Run `pytest tests/test_inbox_api.py -q` → PASS.

- [ ] **Step 5: Terraform and env for the inbox token**

- `terraform/cloud_functions.tf`: delete the `secret_environment_variables { key = "INBOX_API_TOKEN" ... }` block.
- `terraform/secrets.tf:17`: delete `"search-token", # inbox-api bearer auth (clients/inbox_api.py)`.
- `scripts/fetch-env.sh`: delete `INBOX_API_TOKEN=$(secret search-token)`.

(`terraform plan` from this PR runs in `deploy.yml` on merge; expected `~` on the events function env and `-2` accessor bindings on `search-token`.)

- [ ] **Step 6: Smoke script, workflow, skills, docs**

- `scripts/test-api-local.py`: Appendix E; `import subprocess`.
- `deploy-api.yml`: Appendix F, `SERVICE_NAME=tasks-api`, `auth@v3`; remove the `TASKS_API_TOKEN` env.
- Skills `searching-tasks`, `editing-tasks`, `fetching-task`: replace the `TOKEN=$(grep 'tasks_api_token' ...)` line with `TOKEN=$(gcloud auth print-identity-token)   # Cloud Run IAM; your gcloud login is the credential`.
- `verifying-pr-locally/SKILL.md:79-80`: replace with "Auth is Cloud Run IAM, so a local server has no auth at all; requests need no header."
- `CLAUDE.md:19`: `bearer auth via `tasks-api-token`` → `auth is Cloud Run IAM — `roles/run.invoker` per caller in `terraform/api.tf`; callers send `gcloud auth print-identity-token``.
- `README.md:146-148`: replace the three `Auth:` lines with `Auth: Cloud Run IAM. `roles/run.invoker` is granted to Ben's account and the deployer SA in `terraform/api.tf`; send `Authorization: Bearer $(gcloud auth print-identity-token)`. A local server has no auth.`

- [ ] **Step 7: Runbook R3, R4**

Run: `cd ~/src/tasks && ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat(api): Cloud Run IAM replaces the bearer token; call inbox-api with an ID token`. Verify with `searching-tasks`. The `tasks → inbox-api` path stays broken (401 from inbox-api's static check) until Task 17 closes it; triage's email evidence is degraded for that window, so run Tasks 15-17 the same day.

### Task 15: tasks cleanup — delete `tasks-api-token`

**Files:**
- Modify: `~/src/tasks/terraform/api.tf:39-50,70-74`, `terraform/variables.tf:84-88`, `terraform/terraform.tfvars:20`
- Modify: `~/src/tasks/.github/workflows/deploy.yml:56`, `CLAUDE.md:206-220`

- [ ] **Step 1:** Delete `google_secret_manager_secret.tasks_api_token`, its `_version`, `google_secret_manager_secret_iam_member.api_token`, `variable "tasks_api_token"`, the tfvars line (`sed -i '' '/^tasks_api_token/d' terraform/terraform.tfvars`), and `TF_VAR_tasks_api_token:` in `deploy.yml`. `CLAUDE.md:208`: drop `, `search-token``; `CLAUDE.md:212-213`: drop `, and `tasks-api-token``; delete `; the API token is the bearer credential for the tasks-api Cloud Run service — skills read it from `terraform.tfvars`` (lines 218-220), ending that sentence at `webhook posts)`.
- [ ] **Step 2: Runbook R5** — expected plan `-3`. Commit: `chore(terraform): delete tasks-api-token — Cloud Run IAM replaced it`. Then `gh secret delete TF_VAR_TASKS_API_TOKEN --repo bdrolet/tasks`. Run `scripts/fetch-env.sh`.

---

## Phase 5 — `inbox-api`

### Task 16: `inbox-redirect` — split the anonymous redirector out

**Files:**
- Create: `~/src/inbox/api/redirect_app.py`, `~/src/inbox/tests/test_redirect_app.py`
- Modify: `~/src/inbox/api/main.py:5,18`
- Create: `~/src/inbox/terraform/redirect.tf`
- Modify: `~/src/inbox/terraform/cloud_functions.tf:249`, `.github/workflows/deploy-api.yml:42-47`
- Modify: `~/src/inbox/CLAUDE.md` (services table — find the `inbox-api` row with `grep -n 'inbox-api' CLAUDE.md`)

**Interfaces:**
- Produces: Cloud Run service `inbox-redirect`, public, serving only `GET /r/{uuid}`; `google_cloud_run_v2_service.redirect.uri` consumed by the process function's `REDIRECTOR_BASE_URL`.

- [ ] **Step 1: Failing test**

```python
# tests/test_redirect_app.py
from fastapi.testclient import TestClient


def test_redirect_app_serves_only_the_redirector():
    from api.redirect_app import app

    paths = {r.path for r in app.routes if hasattr(r, "methods")}
    assert paths == {"/r/{message_uuid}"}


def test_main_app_no_longer_routes_the_redirector():
    from api.main import app

    assert "/r/{message_uuid}" not in {getattr(r, "path", None) for r in app.routes}


def test_malformed_uuid_is_404_without_db():
    from api.redirect_app import app

    assert TestClient(app).get("/r/not-a-uuid").status_code == 404
```

Run: `cd ~/src/inbox && pytest tests/test_redirect_app.py -q` → FAIL (import error, then main still routes it).

- [ ] **Step 2: The second app**

```python
# api/redirect_app.py
"""inbox-redirect: the one anonymous surface.

GET /r/{uuid} resolves a message to its Outlook webLink and 302s. Its caller
is a tap on an ntfy push notification, which carries no Google credential,
so this runs as its own public Cloud Run service (terraform/redirect.tf)
while inbox-api itself is behind Cloud Run IAM. Same image, different
entrypoint (uvicorn api.redirect_app:app)."""

import logging

from fastapi import FastAPI

from api.routers import redirect

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s", force=True)

app = FastAPI(title="inbox-redirect")
app.include_router(redirect.router)
```

In `api/main.py` change the import to `from api.routers import emails, search` and delete `app.include_router(redirect.router)`. Run the test → 3 PASS. Also `pytest tests/ -q` — any existing test hitting `/r/` through `api.main` moves to `api.redirect_app`.

- [ ] **Step 3: Terraform `redirect.tf`**

```hcl
# ---------------------------------------------------------------------------
# inbox-redirect — the one public Cloud Run service.
#
# GET /r/{uuid} is opened from an ntfy push notification on a phone, which
# cannot present a Google credential, so this service keeps roles/run.invoker
# → allUsers. The UUID is the capability (404 on anything else, before the DB
# is touched) and the target is an Outlook URL behind its own login. Same
# image as inbox-api, different entrypoint; least-privilege SA.
# ---------------------------------------------------------------------------
resource "google_service_account" "redirect" {
  account_id   = "inbox-redirect"
  display_name = "Inbox redirect Cloud Run service"
}

resource "google_project_iam_member" "redirect_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.redirect.email}"
}

resource "google_secret_manager_secret_iam_member" "redirect_secrets" {
  for_each  = toset(["inbox-db-password", "msal-token-cache", "client-id", "client-secret", "tenant-id"])
  secret_id = google_secret_manager_secret.secrets[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.redirect.email}"
}

# The Graph client writes refreshed tokens back to the MSAL cache.
resource "google_secret_manager_secret_iam_member" "redirect_msal_version_manager" {
  secret_id = google_secret_manager_secret.secrets["msal-token-cache"].secret_id
  role      = "roles/secretmanager.secretVersionManager"
  member    = "serviceAccount:${google_service_account.redirect.email}"
}

resource "google_artifact_registry_repository_iam_member" "redirect_ar_reader" {
  repository = google_artifact_registry_repository.inbox.name
  location   = var.region
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.redirect.email}"
}

resource "google_cloud_run_v2_service" "redirect" {
  name     = "inbox-redirect"
  location = var.region

  template {
    service_account = google_service_account.redirect.email
    timeout         = "30s"

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image   = local.api_image
      command = ["uvicorn"]
      args    = ["api.redirect_app:app", "--host", "0.0.0.0", "--port", "8080"]

      resources {
        limits = {
          memory = "256Mi"
        }
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "CLOUD_SQL_CONNECTION_NAME"
        value = data.google_sql_database_instance.inbox.connection_name
      }
      env {
        name  = "POSTGRES_USER"
        value = var.db_user
      }
      env {
        name  = "POSTGRES_DB"
        value = "app"
      }
      env {
        name  = "MSAL_SECRET_NAME"
        value = "msal-token-cache"
      }
      env {
        name = "POSTGRES_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["inbox-db-password"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "CLIENT_ID"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["client-id"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "CLIENT_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["client-secret"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "TENANT_ID"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["tenant-id"].secret_id
            version = "latest"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.apis,
    data.google_sql_database_instance.inbox,
    google_artifact_registry_repository.inbox,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "redirect_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.redirect.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "redirect_deployer_run_developer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.redirect.name
  role     = "roles/run.developer"
  member   = "serviceAccount:${var.deployer_sa}"
}

output "redirect_url" {
  value = google_cloud_run_v2_service.redirect.uri
}
```

Check `MSAL_SECRET_NAME` and any other env the Graph client reads by comparing against the `api` service's env block in `api.tf`; copy any that `clients/graph.py` or `clients/msal_auth.py` require (`grep -n 'os.environ' clients/graph.py clients/msal*.py clients/db.py`) and that are not listed above.

In `cloud_functions.tf:249` change `REDIRECTOR_BASE_URL = google_cloud_run_v2_service.api.uri` to `google_cloud_run_v2_service.redirect.uri`.

- [ ] **Step 4: Deploy workflow**

After the existing `gcloud run deploy inbox-api ...` step add:

```yaml
      - name: Deploy inbox-redirect (same image)
        run: |
          gcloud run deploy inbox-redirect \
            --image us-central1-docker.pkg.dev/bens-project-462804/inbox/inbox-api:latest \
            --region us-central1 \
            --project bens-project-462804
```

- [ ] **Step 5: Docs** — in `CLAUDE.md`'s services table add a row: `| Cloud Run | `inbox-redirect` | `GET /r/{uuid}` only, public by design (ntfy taps); same image as inbox-api, entrypoint `api.redirect_app:app`; SA `inbox-redirect@` with DB + MSAL + Azure app secrets only |`.

- [ ] **Step 6: Lint, test, PR, merge, verify**

Run: `ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat: split the /r redirector into its own public Cloud Run service`. Merge: `deploy.yml` creates the service (with the current image, whose `api.redirect_app` module now exists since the same PR ships it) and `deploy-api.yml` deploys both. Then:

```bash
R=$(cd ~/src/inbox/terraform && terraform output -raw redirect_url)
curl -s -o /dev/null -w '%{http_code}\n' $R/r/not-a-uuid   # 404
```

Run the `send-test-notification` skill, tap the link on the phone, land in Outlook. Old links already in notifications point at `inbox-api/r/...` and keep working until Task 17 removes the route there; that is the accepted break.

### Task 17: inbox Terraform — grants, audience, close `inbox-api`

**Files:**
- Modify: `~/src/inbox/terraform/api.tf:19-135`, `terraform/variables.tf` (append)

- [ ] **Step 1: Variable, data sources, invokers**

Append to `variables.tf`:

```hcl
variable "api_invoker_users" {
  description = "Google accounts granted roles/run.invoker on inbox-api (laptop skills, scripts)"
  type        = list(string)
  default     = ["ben@drolet.cloud"]
}
```

Replace `# Allow unauthenticated invocations — bearer token auth enforced in app code via SEARCH_TOKEN` and the `api_public` resource with:

```hcl
# Callers of inbox-api. Cloud Run IAM is the only authentication: there is no
# app-level token. tasks' events and webhook CFs search and read mail for
# triage (tasks/clients/inbox_api.py); their SAs live in tasks' terraform, so
# they are resolved by account id.
data "google_service_account" "tasks_cfs" {
  for_each   = toset(["tasks-events-cf", "tasks-webhook-cf"])
  account_id = each.key
  project    = var.project_id
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_users" {
  for_each = toset(var.api_invoker_users)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "user:${each.value}"
}

resource "google_cloud_run_v2_service_iam_member" "api_invoker_tasks" {
  for_each = data.google_service_account.tasks_cfs
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${each.value.email}"
}
```

- [ ] **Step 2: Audience and env** — in the `api` service add `custom_audiences = ["https://inbox-api.drolet.cloud"]`; delete the `env { name = "SEARCH_TOKEN" ... }` block.

- [ ] **Step 3: Runbook R1, R2** — `SVC=inbox-api URL=https://inbox-api.drolet.cloud`. Expected plan `+3`, `-1`, `~1`. Commit: `feat(terraform): inbox-api authenticates with Cloud Run IAM`.

### Task 18: inbox app — drop `_verify_token`, log caller, skills

**Files:**
- Create: `~/src/inbox/api/caller.py` (Appendix A), `~/src/inbox/tests/test_caller.py` (Appendix B)
- Delete: `~/src/inbox/tests/test_api_auth_interim.py`
- Modify: `~/src/inbox/api/main.py`, `api/routers/search.py:1-22,50`, `api/routers/emails.py:1-25,197,223,244,263,282,291`, `tests/test_emails_router.py:12-15`
- Modify: skills `searching-inbox-emails:29`, `fetching-inbox-email:23`, `sending-inbox-email:21`, `verifying-pr-locally:41,49-53` under `~/src/inbox/.claude/skills/`
- Modify: `~/src/inbox/CLAUDE.md:171`, `.env.example:54`

- [ ] **Step 1: Appendix B → `tests/test_caller.py`; ImportError. Appendix A → `api/caller.py`; 5 PASS.**

- [ ] **Step 2: Remove the token check**

In `search.py` and `emails.py`: delete `_bearer = HTTPBearer(auto_error=False)`, the `_verify_token` function, every `_: None = Depends(_verify_token)` parameter, and the now-unused imports (`secrets`, `Security`, `HTTPAuthorizationCredentials`, `HTTPBearer`, possibly `os` and `Depends` — `ruff check` lists them). `git rm tests/test_api_auth_interim.py`. In `tests/test_emails_router.py` delete the `_no_auth` fixture. In `api/main.py` after `app = FastAPI(title="inbox-api")` add `caller.install(app)`.

- [ ] **Step 3: Skills and docs**

- `searching-inbox-emails`, `fetching-inbox-email`, `sending-inbox-email`: replace the `TOKEN=$(grep 'search_token' ...)` line with `TOKEN=$(gcloud auth print-identity-token)   # Cloud Run IAM; your gcloud login is the credential`.
- `verifying-pr-locally`: line 41 drop `-u SEARCH_TOKEN`; lines 49-50 `TOKEN=$(gcloud auth print-identity-token)` and the curl against `https://inbox-api.drolet.cloud/search`; delete the paragraph at 53 about probing token auth.
- `CLAUDE.md:171`: delete the `search-token` row.
- `.env.example`: delete `SEARCH_TOKEN=`.

- [ ] **Step 4: Runbook R3, R4**

Run: `cd ~/src/inbox && ruff check . && ruff format --check . && pytest tests/ -q`. Commit: `feat(api): Cloud Run IAM replaces the bearer token; log the caller`. Verify with `searching-inbox-emails`, then create a task through the tasks pipeline (any inbound mail that triages) and:

```bash
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=inbox-api AND textPayload:"caller=tasks-events-cf@"' --project bens-project-462804 --limit 3 --format='value(textPayload)'
```

### Task 19: inbox cleanup — delete `search-token`

**Files:**
- Modify: `~/src/inbox/terraform/secrets.tf` (the `secrets` map entry and `var.search_token` version), `terraform/search.tf:40-44`, `terraform/variables.tf:97-101`, `terraform/terraform.tfvars:18`
- Modify: `~/src/inbox/.github/workflows/deploy.yml:56`

- [ ] **Step 1:** Find every reference: `grep -rn 'search_token\|search-token' terraform/`. Remove `"search-token"` from the `secrets` map, the `google_secret_manager_secret_version` fed by `var.search_token`, `google_secret_manager_secret_iam_member.search_cf_search_token`, `variable "search_token"`, the tfvars line (`sed -i '' '/^search_token/d' terraform/terraform.tfvars` — never print that file), and `TF_VAR_search_token:` in `deploy.yml`.
- [ ] **Step 2: Runbook R5** — expected plan `-3`. Commit: `chore(terraform): delete search-token — Cloud Run IAM replaced it`. Then `gh secret delete TF_VAR_SEARCH_TOKEN --repo bdrolet/inbox`.

---

## Phase 6 — platform docs

### Task 20: infra — CLAUDE.md networking note, spec status

**Files:**
- Modify: `~/src/infra/CLAUDE.md` (networking section, option 2)
- Modify: `~/src/infra/docs/specs/2026-09-22-api-auth-iam-design.md:3`

- [ ] **Step 1:** Under option 2 (`API or service → Cloud Run`) add: `Cloud Run APIs authenticate with IAM: grant `roles/run.invoker` per caller (`user:` for the laptop, the caller's SA for service-to-service), set `custom_audiences` to the service's hostname, and never `allUsers`. `allUsers` is reserved for endpoints a third party or a phone must reach anonymously — today the webhook functions and `inbox-redirect`. Callers send `gcloud auth print-identity-token`; services mint tokens via the metadata server (`clients/gcp_auth.py` in tasks and inbox). See `docs/specs/2026-09-22-api-auth-iam-design.md`.`
- [ ] **Step 2:** Spec `**Status:** proposed` → `**Status:** implemented`.
- [ ] **Step 3:** Commit on `main` as earlier spec commits were: `docs: Cloud Run APIs are IAM-authenticated; mark the auth spec implemented`.

---

## Self-review

**Spec coverage.** §1 IAM: Tasks 2, 6, 10, 13, 17. §2 app code + middleware: Tasks 3, 7, 11, 14, 18 (Appendix A/B). §3 skills/scripts: same tasks; Python clients: Tasks 4, 9, 14 (Appendix C/D); `inbox_api_url` → domain: Task 13. §4 redirect split: Task 16. §5 secrets removed: Tasks 5, 8, 12, 15, 19. Migration order and interim fix: Task 1 then phases 1-5 in spec order. Verification: runbook R2/R4 plus per-task caller checks. Documentation: Tasks 3, 7, 11, 14, 16, 18, 20. Out-of-scope items untouched.

**Additions beyond the spec, both required to keep CI green:** the deployer SA is granted `run.invoker` on `tasks-api`, `docs-api` and `people-api` because their `deploy-api.yml` smoke tests call the deployed service (Appendix F); `schedule` and `inbox` have no smoke step and get no such grant.

**Type consistency.** `id_token_for(audience: str) -> str` (Appendix C) is what `people_api.py`, `schedule_api.py`, `inbox_api.py` call; `caller.install(app)` and `caller.caller_email(str | None) -> str` (Appendix A) are what every `api/main.py` and Appendix B use; `API_ID_TOKEN` is the env name in Appendix E, F and the schedule/people smoke scripts.
