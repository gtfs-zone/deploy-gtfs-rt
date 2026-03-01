locals {
  prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  auth_fqdn    = "${var.auth_subdomain}.${var.domain}"
  dex_fqdn     = "${var.dex_subdomain}.${var.domain}"
  api_fqdn     = "${var.api_subdomain}.${var.domain}"
uptime_fqdn  = "${var.uptime_subdomain}.${var.domain}"
  status_fqdn  = "${var.status_subdomain}.${var.domain}"
  mqtt_fqdn    = "${var.mqtt_subdomain}.${var.domain}"
  mqtt_ws_fqdn = "${var.mqtt_ws_subdomain}.${var.domain}"

  registry = "git.kcfam.us"

  ttl = 600

  proxy_network_name = (
    var.use_external_traefik
    ? var.external_traefik_network
    : docker_network.proxy_tier.name
  )
}
