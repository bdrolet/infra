---
name: gke-local-setup
description: Use when setting up a new machine to work with the GKE cluster — installing kubectl, gke-gcloud-auth-plugin, authenticating gcloud, configuring Docker for Artifact Registry
---

# GKE Local Setup

Steps to get a new machine fully configured for working with this cluster.

## 1. Install kubectl

```bash
brew install kubectl
```

## 2. Install the GKE auth plugin

```bash
gcloud components install gke-gcloud-auth-plugin
```

## 3. Authenticate gcloud

```bash
gcloud auth login
```

## 4. Configure kubectl for the cluster

```bash
gcloud container clusters get-credentials bens-k8s \
  --region us-central1 --project bens-project-462804
```

## 5. Authenticate Docker for Artifact Registry

Required before pushing images:

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
```

## Verify everything works

```bash
kubectl get nodes
```

## Notes

- Docker Desktop must be running before any `docker build` or `docker push` commands.
- Docker is installed at `/Applications/Docker.app/Contents/Resources/bin/docker` on Mac but may not be on `$PATH` — open Docker Desktop to ensure the CLI is available.
