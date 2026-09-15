resource "cloudflare_zone" "drolet_cloud" {
  account_id = var.account_id
  zone       = "drolet.cloud"
}

# GCP Certificate Manager DNS authorization for *.drolet.cloud wildcard cert
resource "cloudflare_record" "gcp_cert_auth" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "_acme-challenge"
  type    = "CNAME"
  content = "0b444105-a413-4cde-9f67-5bbcb913852d.18.authorize.certificatemanager.goog"
  proxied = false
}

resource "cloudflare_record" "drolet_cloud_www" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "www"
  type    = "CNAME"
  content = "drolet.cloud"
  proxied = false
}

resource "cloudflare_record" "drolet_cloud_mx" {
  zone_id  = cloudflare_zone.drolet_cloud.id
  name     = "@"
  type     = "MX"
  content  = "drolet-cloud.mail.protection.outlook.com"
  priority = 0
}

resource "cloudflare_record" "drolet_cloud_spf" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "@"
  type    = "TXT"
  content = "v=spf1 include:_spf.google.com include:spf.protection.outlook.com -all"
}

resource "cloudflare_record" "drolet_cloud_ms_verify" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "@"
  type    = "TXT"
  content = "v=verifydomain MS=7965088"
}

resource "cloudflare_record" "drolet_cloud_google_verify" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "@"
  type    = "TXT"
  content = "google-site-verification=u--cgn4dU1qJBQSpAJFEhX5RMqJWPjWInjgqDU4vVlw"
}

# The blog is a static Astro site on Cloudflare Pages, deployed on push to
# main in bdrolet/blog. It used to run as a pod behind a standalone GKE
# Ingress, which had its own GCP load balancer (~$18/month) — see D3 in
# docs/specs/2026-09-10-cluster-cost-reduction-design.md.
resource "cloudflare_pages_project" "blog" {
  account_id        = var.account_id
  name              = "blog"
  production_branch = "main"

  build_config {
    build_command   = "npm run build"
    destination_dir = "dist"
  }

  deployment_configs {
    production {
      # Astro 6 needs Node >= 22.12; the Pages build image default is older.
      environment_variables = {
        NODE_VERSION = "22.12.0"
      }
    }
  }

  source {
    type = "github"
    config {
      owner                         = var.github_owner
      repo_name                     = "blog"
      production_branch             = "main"
      pr_comments_enabled           = true
      deployments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "none"
    }
  }
}

resource "cloudflare_record" "blog" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "blog"
  type    = "CNAME"
  content = cloudflare_pages_project.blog.subdomain
  proxied = true

  depends_on = [cloudflare_pages_project.blog]
}

resource "cloudflare_pages_domain" "blog" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.blog.name
  domain       = "blog.drolet.cloud"
}

# observability.drolet.cloud is deliberately absent: D1 deletes the
# self-hosted Grafana it pointed at, and the A record had already been
# dangling at an IP that exists nowhere in the project.

resource "cloudflare_pages_project" "finances" {
  account_id        = var.account_id
  name              = "finances"
  production_branch = "main"

  build_config {
    destination_dir = "output"
  }

  source {
    type = "github"
    config {
      owner                         = var.github_owner
      repo_name                     = "finances"
      production_branch             = "main"
      pr_comments_enabled           = true
      deployments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "none"
    }
  }
}

resource "cloudflare_record" "fin" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "fin"
  type    = "CNAME"
  content = "finances-2b4.pages.dev"
  proxied = true
}

resource "cloudflare_pages_domain" "fin" {
  account_id   = var.account_id
  project_name = "finances"
  domain       = "fin.drolet.cloud"
}

# Cloud Run domain mapping for inbox-api.drolet.cloud.
# The mapping requests a single CNAME to ghs.googlehosted.com (subdomain mapping).
# Must stay DNS-only (proxied = false) so Cloud Run can provision its managed TLS cert.
resource "cloudflare_record" "inbox_api" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "inbox-api"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
  ttl     = 60
}

# Cloud Run domain mapping for tasks-api.drolet.cloud (same shape as inbox-api).
resource "cloudflare_record" "tasks_api" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "tasks-api"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
  ttl     = 60
}

# Cloud Run domain mapping for schedule-api.drolet.cloud (same shape as inbox-api).
resource "cloudflare_record" "schedule_api" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "schedule-api"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
  ttl     = 60
}

# Cloud Run domain mapping for people-api.drolet.cloud (same shape as schedule-api).
resource "cloudflare_record" "people_api" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "people-api"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
  ttl     = 60
}

output "drolet_cloud_nameservers" {
  description = "Cloudflare nameservers to set at GoDaddy for drolet.cloud"
  value       = cloudflare_zone.drolet_cloud.name_servers
}
