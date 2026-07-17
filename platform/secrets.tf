# Shared Secret Manager secrets consumed by multiple repos (inbox + tasks).
# This state owns them; the consuming repos reference them read-only via
# `data "google_secret_manager_secret"`. Do not also define these as resources
# in another state — two states owning the same secret_id fails with
# "already exists".
locals {
  shared_secrets = {
    "asana-api-key"         = var.asana_api_key
    "grafana-otlp-endpoint" = var.grafana_otlp_endpoint
    "grafana-otlp-token"    = var.grafana_otlp_token
    "webhook-label-token"   = var.webhook_label_token
  }
}

resource "google_secret_manager_secret" "shared" {
  for_each  = local.shared_secrets
  secret_id = each.key

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "shared" {
  for_each    = local.shared_secrets
  secret      = google_secret_manager_secret.shared[each.key].id
  secret_data = each.value
}
