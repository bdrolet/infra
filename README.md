# bens-k8s

GKE Autopilot cluster on GCP, managed with Terraform, with a personal devbox workspace.

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/)
- GCP project `bens-project-462804` with billing enabled

### Authenticate

```bash
gcloud auth application-default login
gcloud auth configure-docker us-central1-docker.pkg.dev
```

## Provision the Cluster

```bash
cd terraform
terraform init
terraform apply
```

This creates a GKE Autopilot cluster in `us-central1` and enables the required GCP APIs.

### Configure kubectl

```bash
gcloud container clusters get-credentials bens-k8s --region us-central1 --project bens-project-462804
```

## Devbox

A long-running workspace container you `kubectl exec` into for learning and experimentation.

### How it works

```
Dockerfile (devbox/)        -> Docker image with dev tools
deploy/base/                -> K8s manifests (namespace, PVC, deployment)
deploy/overlays/gke-dev/    -> GKE-specific image reference
```

The Deployment runs `sleep infinity` to keep the pod alive. You connect via `kubectl exec`. A PersistentVolumeClaim keeps `/workspace` data across pod restarts.

### Build and push the image

Create the Artifact Registry repo (one-time):

```bash
gcloud artifacts repositories create devbox \
  --repository-format=docker \
  --location=us-central1 \
  --project=bens-project-462804
```

The repo's cleanup policy lives in `artifact-registry/set-cleanup-policies.sh`.

Build and push:

```bash
cd devbox
docker build --platform linux/amd64 -t us-central1-docker.pkg.dev/bens-project-462804/devbox/devbox:latest .
docker push us-central1-docker.pkg.dev/bens-project-462804/devbox/devbox:latest
```

### Deploy

```bash
kubectl apply -k deploy/overlays/gke-dev/
```

### Connect

```bash
# Find the pod
kubectl get pods -n devbox

# Exec into it
kubectl exec -it -n devbox deployment/devbox -- bash

# Copy files in
kubectl cp myfile.txt devbox/<pod-name>:/workspace/myfile.txt

# Copy files out
kubectl cp devbox/<pod-name>:/workspace/myfile.txt ./myfile.txt
```

### Scale down (stop billing for compute)

```bash
kubectl scale deployment devbox -n devbox --replicas=0
```

Scale back up with `--replicas=1`. The PVC preserves `/workspace` data.

## Tear Down

To remove everything and stop all charges:

```bash
kubectl delete -k deploy/overlays/gke-dev/
cd terraform
terraform destroy
```

## Cost

| Resource | Approximate cost | Notes |
|---|---|---|
| GKE cluster management | **Free** | $74.40/month credit covers one Autopilot cluster |
| Devbox pod (250m CPU, 512Mi) | ~$6-8/month | Billed per-second only while running |
| PVC (10Gi SSD) | ~$1.70/month | Billed even when pod is scaled to 0 |

Scale the deployment to 0 replicas when not in use. Delete the PVC if you don't need the data. Destroy the cluster with Terraform when done entirely.
