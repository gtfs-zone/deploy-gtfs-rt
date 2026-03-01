provider "uptimekuma" {
  endpoint = "https://${var.uptime_subdomain}.${var.domain}"
  username = var.uptime_kuma_username
  password = var.uptime_kuma_password
}
