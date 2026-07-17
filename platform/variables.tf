variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

# ---------------------------------------------------------------------------
# Shared secret values. These secrets are consumed by both the inbox
# (github.com/bdrolet/inbox) and tasks (github.com/bdrolet/tasks) repos, which
# read them read-only via data sources. Ownership (create + version) lives here.
# ---------------------------------------------------------------------------
variable "asana_api_key" {
  description = "Asana personal access token — read by the tasks repo's Cloud Functions"
  type        = string
  sensitive   = true
}

variable "grafana_otlp_endpoint" {
  description = "Grafana Cloud OTLP gateway URL (e.g. https://otlp-gateway-prod-us-west-0.grafana.net/otlp)"
  type        = string
  sensitive   = true
}

variable "grafana_otlp_token" {
  description = "Grafana Cloud OTLP Basic Auth token: base64(instance_id:api_key)"
  type        = string
  sensitive   = true
}

variable "webhook_label_token" {
  description = "Bearer token required on /label requests from ntfy action buttons. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
}
