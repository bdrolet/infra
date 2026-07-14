---
name: gcloud-auth
description: Use when gcloud authentication has expired, kubectl fails with credential errors, gke-gcloud-auth-plugin returns exit code 1, or any GCP command returns an auth/token error. Use when the user asks to re-authenticate to GCP or refresh gcloud credentials.
---

# GCloud Auth

Re-authenticate gcloud and verify kubectl access.

## 1. Log in

```bash
gcloud auth login
```

This opens a browser OAuth flow. Wait for "You are now logged in as [...]".

## 2. Set the project

```bash
gcloud config set project bens-project-462804
```

## 3. Verify kubectl works

```bash
kubectl get nodes
```

## If kubectl still fails

The kubeconfig context may have drifted. Re-fetch it:

```bash
gcloud container clusters get-credentials bens-k8s \
  --region us-central1 --project bens-project-462804
```

## Application Default Credentials (Terraform / SDKs)

`gcloud auth login` covers kubectl and gcloud CLI. If Terraform or a GCP SDK also fails, run this separately:

```bash
gcloud auth application-default login
```
