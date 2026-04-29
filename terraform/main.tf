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
