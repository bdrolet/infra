# infra namespace — shared Gateway

The `infra` namespace owns the single shared GKE Gateway API Gateway.
All team HTTPRoutes attach to this Gateway via `parentRefs`.

## GCP Certificate Manager setup

Run once before applying `gateway.yaml`:

```bash
# DNS authorization for wildcard cert (requires a _acme-challenge TXT record in your DNS)
gcloud certificate-manager dns-authorizations create drolet-cloud-auth \
  --domain="drolet.cloud"

# Get the DNS record to add (CNAME), then add it in your DNS provider
gcloud certificate-manager dns-authorizations describe drolet-cloud-auth

# Create the wildcard cert (provisions after DNS record is live)
gcloud certificate-manager certificates create wildcard-drolet-cloud \
  --domains="*.drolet.cloud,drolet.cloud" \
  --dns-authorizations=drolet-cloud-auth

# Create the cert map and wildcard entry
gcloud certificate-manager maps create drolet-cloud-cert-map
gcloud certificate-manager maps entries create wildcard-entry \
  --map=drolet-cloud-cert-map \
  --hostname="*.drolet.cloud" \
  --certificate=wildcard-drolet-cloud
```

## Apply order

```bash
kubectl apply -f k8s/infra/namespace.yaml
kubectl apply -f k8s/infra/gateway.yaml
```

The Gateway provisions a GCP Global External Application Load Balancer (~$18/month for the
forwarding rule). All routes share this single load balancer — do not create additional
LoadBalancer Services or standalone Ingress resources.
