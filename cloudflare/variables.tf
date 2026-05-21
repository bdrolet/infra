variable "cloudflare_api_token" {
  description = "Cloudflare API token with Pages:Edit and DNS:Edit permissions"
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone ID for the root domain"
  type        = string
}

variable "domain_name" {
  description = "Root domain name (e.g. example.com)"
  type        = string
}

variable "subdomain" {
  description = "Subdomain for the consulting site (e.g. consulting → consulting.example.com)"
  type        = string
  default     = "consulting"
}

variable "github_owner" {
  description = "GitHub username or org that owns the consulting repo"
  type        = string
}
