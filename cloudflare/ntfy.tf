variable "ntfy_ip" {
  description = "Static external IP of the ntfy GCP VM (from inbox terraform output ntfy_ip)"
  type        = string
}

resource "cloudflare_record" "ntfy" {
  zone_id = var.zone_id
  name    = "ntfy"
  type    = "A"
  content = var.ntfy_ip
  proxied = false
  ttl     = 60
}
