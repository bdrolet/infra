resource "cloudflare_pages_project" "consulting" {
  account_id        = var.account_id
  name              = "consulting"
  production_branch = "main"

  build_config {
    build_command   = "npm run build"
    destination_dir = "out"
  }

  source {
    type = "github"
    config {
      owner                         = var.github_owner
      repo_name                     = "consulting-website"
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
  domain       = var.domain_name
}

resource "cloudflare_record" "consulting" {
  zone_id = var.zone_id
  name    = "@"
  type    = "CNAME"
  content = cloudflare_pages_project.consulting.subdomain
  proxied = true

  depends_on = [cloudflare_pages_project.consulting]
}

resource "cloudflare_record" "ms_verify" {
  zone_id = var.zone_id
  name    = "@"
  type    = "TXT"
  content = "MS=ms29767756"
}

# The consulting blog: a static Astro site on Cloudflare Pages, deployed on
# push to main in bdrolet/consulting-blog. Same shape as the personal blog in
# drolet-cloud.tf; spec in the consulting repo,
# docs/superpowers/specs/2026-10-14-consulting-blog-design.md.
resource "cloudflare_pages_project" "consulting_blog" {
  account_id        = var.account_id
  name              = "consulting-blog"
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
      repo_name                     = "consulting-blog"
      production_branch             = "main"
      pr_comments_enabled           = true
      deployments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "none"
    }
  }
}

resource "cloudflare_record" "consulting_blog" {
  zone_id = var.zone_id
  name    = "blog"
  type    = "CNAME"
  content = cloudflare_pages_project.consulting_blog.subdomain
  proxied = true

  depends_on = [cloudflare_pages_project.consulting_blog]
}

resource "cloudflare_pages_domain" "consulting_blog" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.consulting_blog.name
  domain       = "blog.drolet.ai"
}
