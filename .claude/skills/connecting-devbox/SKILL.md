---
name: connecting-devbox
description: Use when connecting to the devbox, exec-ing into the pod, copying files to/from the devbox, or managing the devbox lifecycle (scaling up/down)
---

# Connecting to the Devbox

The devbox is a long-running workspace container on GKE Autopilot. It runs in the `devbox` namespace as a Deployment with a single replica.

## Connect

```bash
kubectl exec -it -n devbox deployment/devbox -- bash
```

## Copy Files

```bash
# Get the pod name
POD=$(kubectl get pods -n devbox -o jsonpath='{.items[0].metadata.name}')

# Copy in
kubectl cp myfile.txt devbox/$POD:/workspace/myfile.txt

# Copy out
kubectl cp devbox/$POD:/workspace/myfile.txt ./myfile.txt
```

## Lifecycle

```bash
# Scale down (stops compute billing, PVC data persists)
kubectl scale deployment devbox -n devbox --replicas=0

# Scale back up
kubectl scale deployment devbox -n devbox --replicas=1

# Check status
kubectl get pods -n devbox
```

## Troubleshooting

If the pod is `Pending`, Autopilot is provisioning a node — wait 1-2 minutes. Check events with:

```bash
kubectl describe pod -n devbox -l app=devbox
```
