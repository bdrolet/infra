resource "cloudflare_pages_project" "consulting" {
  account_id        = var.account_id
  name              = "consulting"
  production_branch = "main"

  source {
    type = "github"
    config {
      owner                         = var.github_owner
      repo_name                     = "consulting"
      production_branch             = "main"
      pr_comments_enabled           = true
      deployments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "custom"
      preview_branch_includes       = ["preview", "staging"]
    }
  }
}

resource "cloudflare_pages_domain" "consulting" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.consulting.name
  domain       = "${var.subdomain}.${var.domain_name}"
}

resource "cloudflare_record" "consulting" {
  zone_id = var.zone_id
  name    = var.subdomain
  type    = "CNAME"
  value   = "${cloudflare_pages_project.consulting.name}.pages.dev"
  proxied = true

  depends_on = [cloudflare_pages_project.consulting]
}
