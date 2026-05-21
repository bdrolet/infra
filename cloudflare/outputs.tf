output "pages_url" {
  description = "Cloudflare Pages default URL"
  value       = "https://${cloudflare_pages_project.consulting.name}.pages.dev"
}

output "custom_domain" {
  description = "Custom domain URL for the consulting site"
  value       = "https://${var.domain_name}"
}

output "pages_project_name" {
  description = "Cloudflare Pages project name"
  value       = cloudflare_pages_project.consulting.name
}
