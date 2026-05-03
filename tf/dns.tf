resource "porkbun_dns_record" "root" {
  domain    = var.domain
  subdomain = ""
  type      = "A"
  content   = var.server_ip
  ttl       = local.ttl
}

resource "porkbun_dns_record" "subdomains" {
  for_each = toset([
    var.auth_subdomain,
    var.dex_subdomain,
    var.api_subdomain,
    var.api_admin_subdomain,
    var.uptime_subdomain,
    var.status_subdomain,
    var.mqtt_subdomain,
    var.mqtt_ws_subdomain,
  ])
  domain    = var.domain
  subdomain = each.key
  type      = "CNAME"
  content   = var.domain
  ttl       = local.ttl
}
