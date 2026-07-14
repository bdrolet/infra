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

resource "google_artifact_registry_repository" "openclaw" {
  repository_id = "openclaw"
  format        = "DOCKER"
  location      = var.region
  description   = "OpenClaw gateway image"

  depends_on = [google_project_service.artifactregistry]
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
