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

variable "billing_account_id" {
  description = "GCP billing account the project bills to"
  type        = string
  default     = "011161-84DB9A-69D458"
}

variable "monthly_budget_usd" {
  description = "Monthly budget amount, in USD, that alert thresholds are a percentage of"
  type        = number
  default     = 75
}
