terraform {
  required_version = ">= 1.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Uncomment to enable Terraform Cloud remote state
  # backend "remote" {
  #   organization = "your-org-name"
  #   workspaces {
  #     name = "cloudflare"
  #   }
  # }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
