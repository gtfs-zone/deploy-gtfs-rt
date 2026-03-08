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
  name                  = "https://${var.api_subdomain}.${var.domain}/health"
  url                   = "https://${var.api_subdomain}.${var.domain}/health"
  interval              = 60
  max_retries           = 3
  max_redirects         = 10
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

# ─── Internal HTTP monitors ───────────────────────────────────────────────────

resource "uptimekuma_monitor_http" "rt_api_internal" {
  name                  = "http://gtfs-api:8000/health"
  url                   = "http://gtfs-api:8000/health"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

resource "uptimekuma_monitor_http" "rt_api_admin_internal" {
  name                  = "http://gtfs-manager:8001/openapi.json"
  url                   = "http://gtfs-manager:8001/openapi.json"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

resource "uptimekuma_monitor_http" "oauth2_proxy_internal" {
  name                  = "http://oauth2-proxy:4180/ping"
  url                   = "http://oauth2-proxy:4180/ping"
  interval              = 60
  max_retries           = 3
  accepted_status_codes = ["200"]
  notification_ids      = local.notification_ids
  active                = true
}

# ─── TCP port monitors ────────────────────────────────────────────────────────

resource "uptimekuma_monitor_tcp_port" "traefik_http" {
  name             = "traefik:80"
  hostname         = "traefik"
  port             = 80
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "traefik_https" {
  name             = "traefik:443"
  hostname         = "traefik"
  port             = 443
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "postgres" {
  name             = "postgres:5432"
  hostname         = "postgres"
  port             = 5432
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "redis" {
  name             = "redis:6379"
  hostname         = "redis"
  port             = 6379
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "nanomq_mqtt" {
  name             = "nanomq:1883"
  hostname         = "nanomq"
  port             = 1883
  interval         = 30
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_tcp_port" "nanomq_ws" {
  name             = "nanomq:8083"
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
  docker_container = "traefik"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "postgres" {
  name             = "${local.p}postgres"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}postgres"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "redis" {
  name             = "${local.p}redis"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}redis"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "nanomq" {
  name             = "${local.p}nanomq"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}nanomq"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

# Auth
resource "uptimekuma_monitor_docker" "oauth2_proxy" {
  name             = "${local.p}oauth2-proxy"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}oauth2-proxy"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "dex" {
  name             = "${local.p}dex"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}dex"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

# Application
resource "uptimekuma_monitor_docker" "rt_api" {
  name             = "${local.p}gtfs-api"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}gtfs-api"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "rt_api_admin" {
  name             = "${local.p}gtfs-manager"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}gtfs-manager"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "bridge" {
  name             = "${local.p}vehicle-poser"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}vehicle-poser"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "trip_updogger" {
  name             = "${local.p}trip-updogger"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}trip-updogger"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "celery_worker" {
  name             = "${local.p}celery-worker"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}celery-worker"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "celery_beat" {
  name             = "${local.p}celery-beat"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}celery-beat"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}

resource "uptimekuma_monitor_docker" "uptime_kuma" {
  name             = "${local.p}uptime-kuma"
  docker_host_id   = uptimekuma_docker_host.local.id
  docker_container = "${local.p}uptime-kuma"
  interval         = 60
  max_retries      = 3
  notification_ids = local.notification_ids
  active           = true
}
