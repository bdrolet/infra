terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "bens-project-462804-tf-state"
    prefix = "platform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
