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

resource "cloudflare_record" "blog" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "blog"
  type    = "A"
  content = "8.233.60.2"
  proxied = false
  ttl     = 60
}

resource "cloudflare_record" "observability" {
  zone_id = cloudflare_zone.drolet_cloud.id
  name    = "observability"
  type    = "A"
  content = "8.233.220.63"
  proxied = false
  ttl     = 60
}

output "drolet_cloud_nameservers" {
  description = "Cloudflare nameservers to set at GoDaddy for drolet.cloud"
  value       = cloudflare_zone.drolet_cloud.name_servers
}
