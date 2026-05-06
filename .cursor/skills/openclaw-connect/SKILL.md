---
name: openclaw-connect
description: Use when connecting to OpenClaw running in k8s, port-forwarding the UI, checking logs, or setting up Claude CLI auth in the pod
---

# Connecting to OpenClaw

OpenClaw runs in the `apps` namespace as a `ClusterIP` service on port `18789`. Access it via `kubectl port-forward`.

## Port-forward the UI

Port `18789` is typically used by a local OpenClaw instance, so use `18790` for the k8s one:

```bash
kubectl port-forward -n apps svc/openclaw 18790:18789
```

Then open: `http://localhost:18790`

## Gateway token (UI login)

The Control UI requires a token. Retrieve it from the pod:

```bash
kubectl exec -n apps deployment/openclaw -- sh -c "cat /home/node/.openclaw/openclaw.json"
```

Paste the value of `gateway.auth.token` into the Control UI settings in the browser.

## Claude CLI auth

OpenClaw is configured to use Claude CLI as its backend. If the pod has been redeployed and needs re-authentication:

```bash
kubectl exec -it -n apps deployment/openclaw -- claude auth login
```

Complete the OAuth flow in the browser.

## Check logs

```bash
kubectl logs -n apps deployment/openclaw --tail=50
```

## Rebuild & redeploy the image

If the Dockerfile changes (e.g. upgrading openclaw or claude-code versions):

```bash
docker build --platform linux/amd64 \
  -t us-central1-docker.pkg.dev/bens-project-462804/openclaw/openclaw:latest \
  k8s/openclaw/

docker push us-central1-docker.pkg.dev/bens-project-462804/openclaw/openclaw:latest

kubectl rollout restart deployment/openclaw -n apps
kubectl rollout status deployment/openclaw -n apps
```

## Troubleshooting

- **Pod crashing with EPIPE** — Claude CLI is configured but not installed in the image. Rebuild and push.
- **UI shows `token_missing`** — paste the gateway token in Control UI settings (see above).
- **Port 18789 already in use** — that's your local OpenClaw; use `18790` for the k8s instance.
- **`docker push` unauthenticated** — run `gcloud auth configure-docker us-central1-docker.pkg.dev` first.
