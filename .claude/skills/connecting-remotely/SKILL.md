---
name: connecting-remotely
description: Use when connecting to the GKE cluster, devbox, or services like Postgres from another machine, or when asking about remote access, port-forwarding, or cross-machine kubectl setup
---

# Connecting Remotely

Access the GKE cluster from any machine using `gcloud` + `kubectl`. Never expose pods publicly.

## Setup on a new machine

```bash
# Install gcloud CLI, then:
gcloud auth login
gcloud components install gke-gcloud-auth-plugin
gcloud container clusters get-credentials bens-k8s \
  --region us-central1 --project bens-project-462804
```

## Access patterns

### Shell into the devbox

```bash
kubectl exec -it -n devbox deployment/devbox -- bash
```

### Port-forward a service (e.g. Postgres)

```bash
kubectl port-forward -n <namespace> svc/<service-name> <local-port>:<remote-port>
```

This tunnels `localhost:<local-port>` to the in-cluster service. No public IP needed.

### Copy files

```bash
POD=$(kubectl get pods -n devbox -o jsonpath='{.items[0].metadata.name}')
kubectl cp myfile.txt devbox/$POD:/workspace/myfile.txt
kubectl cp devbox/$POD:/workspace/myfile.txt ./myfile.txt
```

## What to avoid

- **No LoadBalancer Services** for dev workloads — exposes a public IP with no auth.
- **No direct firewall rules** to reach pods.
- **No SSH servers** inside containers — `kubectl exec` is the equivalent, authenticated by Google IAM.

## Security model

All access goes through the GKE API server, authenticated by your Google identity via `gcloud`. No VPN or special networking required.
