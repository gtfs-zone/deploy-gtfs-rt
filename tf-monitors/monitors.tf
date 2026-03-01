resource "uptimekuma_docker_host" "local" {
  name          = "Local Docker Host"
  docker_type   = "socket"
  docker_daemon = "/var/run/docker.sock"
}

locals {
  notification_ids = [uptimekuma_notification.telegram.id]
  p                = var.name_prefix != "" ? "${var.name_prefix}-" : ""
}

# ─── External HTTP monitors ───────────────────────────────────────────────────

resource "uptimekuma_monitor_http" "api_external" {
  name                  = "GTFS-RT API"
  url                   = "https://api.${var.domain}"
  interval              = 60
  max_retries           = 3
  max_redirects         = 10
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

resource "uptimekuma_monitor_http" "grafana_external" {
  name                  = "Grafana"
  url                   = "https://grafana.${var.domain}"
  interval              = 60
  max_retries           = 3
  max_redirects         = 10
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

# ─── Internal HTTP monitors ───────────────────────────────────────────────────

resource "uptimekuma_monitor_http" "prometheus_internal" {
  name                  = "Prometheus (internal)"
  url                   = "http://prometheus:9090/-/healthy"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

resource "uptimekuma_monitor_http" "grafana_internal" {
  name                  = "Grafana (internal)"
  url                   = "http://grafana:3000/api/health"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

resource "uptimekuma_monitor_http" "fastapi_internal" {
  name                  = "FastAPI (internal)"
  url                   = "http://fastapi:8000/health"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

resource "uptimekuma_monitor_http" "authelia_internal" {
  name                  = "Authelia (internal)"
  url                   = "http://authelia:9091/api/health"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

# ─── TCP port monitors ────────────────────────────────────────────────────────

resource "uptimekuma_monitor_tcp_port" "traefik_http" {
  name             = "Traefik HTTP"
  hostname         = "traefik"
  port             = 80
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "traefik_https" {
  name             = "Traefik HTTPS"
  hostname         = "traefik"
  port             = 443
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "postgres" {
  name             = "PostgreSQL"
  hostname         = "postgres"
  port             = 5432
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "redis" {
  name             = "Redis"
  hostname         = "redis"
  port             = 6379
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "nanomq_mqtt" {
  name             = "NanoMQ MQTT (1883)"
  hostname         = "nanomq"
  port             = 1883
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "nanomq_ws" {
  name             = "NanoMQ WebSocket (8083)"
  hostname         = "nanomq"
  port             = 8083
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

# ─── Docker container monitors ───────────────────────────────────────────────

# Infrastructure
resource "uptimekuma_monitor_docker" "traefik" {
  name             = "traefik"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}traefik"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "postgres" {
  name             = "postgres"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}postgres"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "redis" {
  name             = "redis"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}redis"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "nanomq" {
  name             = "nanomq"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}nanomq"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

# Auth
resource "uptimekuma_monitor_docker" "authelia" {
  name             = "authelia"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}authelia"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "dex" {
  name             = "dex"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}dex"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

# Application
resource "uptimekuma_monitor_docker" "fastapi" {
  name             = "fastapi"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}fastapi"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "bridge" {
  name             = "bridge"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}bridge"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

# Monitoring stack
resource "uptimekuma_monitor_docker" "prometheus" {
  name             = "prometheus"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}prometheus"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "grafana" {
  name             = "grafana"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}grafana"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "node_exporter" {
  name             = "node-exporter"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}node-exporter"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "cadvisor" {
  name             = "cadvisor"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}cadvisor"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "uptime_kuma" {
  name             = "uptime-kuma"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}uptime-kuma"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}
