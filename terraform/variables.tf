variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "bens-project-462804"
}

variable "region" {
  description = "GCP region for the cluster"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Name of the GKE Autopilot cluster"
  type        = string
  default     = "bens-k8s"
}

# No default: this repo is public, and the billing account ID is a stable,
# unrotatable identifier. Set it in terraform.tfvars (gitignored). Recover it
# with:
#   gcloud billing projects describe <project> --format='value(billingAccountName)'
variable "billing_account_id" {
  description = "GCP billing account the project bills to, e.g. 0X0X0X-XXXXXX-XXXXXX"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget amount, in USD, that alert thresholds are a percentage of"
  type        = number
  default     = 75
}
