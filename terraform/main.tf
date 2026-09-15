provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "blog" {
  repository_id = "blog"
  format        = "DOCKER"
  location      = var.region
  description   = "Astro blog image"

  depends_on = [google_project_service.artifactregistry]
}

resource "google_compute_firewall" "gke_health_checks" {
  name    = "gke-bens-k8s-allow-health-checks"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  description   = "Allow GCP load balancer health checks to reach pods on port 80"

  depends_on = [google_project_service.compute]
}

resource "google_container_cluster" "autopilot" {
  name     = var.cluster_name
  location = var.region

  enable_autopilot = true

  ip_allocation_policy {}

  # Cloud Monitoring (D8) — see the observability section of CLAUDE.md. The
  # optional metric component groups billed ~$42/month as Prometheus samples
  # (cAdvisor's container_network_* counters alone were 92.7%) and nothing read
  # them; SYSTEM_COMPONENTS is free and stays.
  #
  # Two fields Autopilot will not let this cluster set — do not add them back:
  # managed_prometheus { enabled = false } is rejected with HTTP 400, and
  # advanced_datapath_observability_config { enable_metrics = false } is
  # accepted then ignored, so declaring it leaves a permanent plan diff.
  # Neither costs anything.
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # Deliberately no logging_config: SYSTEM_COMPONENTS + WORKLOADS logging must
  # stay as-is. Cloud Logging is the only destination for container logs, so
  # trimming it the way monitoring was trimmed above leaves logs nowhere.

  depends_on = [
    google_project_service.compute,
    google_project_service.container,
  ]
}

resource "google_project_service" "bigquery" {
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "billing_exporter" {
  repository_id = "billing-exporter"
  format        = "DOCKER"
  location      = var.region
  description   = "GCP billing exporter image"

  depends_on = [google_project_service.artifactregistry]
}

# --- Grafana Alloy (Cloud Monitoring reader) ---

resource "google_service_account" "alloy" {
  account_id   = "alloy-gcp"
  display_name = "Grafana Alloy (Cloud Monitoring reader)"
}

resource "google_project_iam_member" "alloy_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.alloy.email}"
}

resource "google_service_account_iam_member" "alloy_workload_identity" {
  service_account_id = google_service_account.alloy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[observability/alloy]"
}

# --- Billing Exporter (BigQuery reader) ---

resource "google_service_account" "billing_exporter" {
  account_id   = "billing-exporter"
  display_name = "GCP Billing Exporter (BigQuery reader)"
}

resource "google_bigquery_dataset_iam_member" "billing_exporter_viewer" {
  dataset_id = "billing_export"
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.billing_exporter.email}"
}

resource "google_project_iam_member" "billing_exporter_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.billing_exporter.email}"
}

resource "google_service_account_iam_member" "billing_exporter_workload_identity" {
  service_account_id = google_service_account.billing_exporter.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[apps/billing-exporter]"
}

# --- Billing budget (D6) ---

# The Billing Budgets API bills the request to a quota project, which the
# default provider does not send. Without user_project_override the call is
# attributed to gcloud's own client project and fails with SERVICE_DISABLED.
provider "google" {
  alias                 = "billing"
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

resource "google_project_service" "billingbudgets" {
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

data "google_project" "this" {
  project_id = var.project_id
}

# Alerts go to the billing account's default IAM recipients — billing account
# admins and users with the Billing Account Costs Manager role. That is the
# behaviour when no all_updates_rule is set, so no notification channel or
# Pub/Sub topic is needed.
resource "google_billing_budget" "project" {
  provider = google.billing

  billing_account = var.billing_account_id
  display_name    = "${var.project_id} monthly budget"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.billingbudgets]
}
