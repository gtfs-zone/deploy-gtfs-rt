# ── Traefik ──────────────────────────────────────────────────────────────────

resource "docker_container" "traefik" {
  count   = var.use_external_traefik ? 0 : 1
  name    = "${local.prefix}traefik"
  image   = docker_image.traefik.image_id
  restart = "always"

  env = [
    "PORKBUN_API_KEY=${var.porkbun_api_key}",
    "PORKBUN_SECRET_API_KEY=${var.porkbun_secret_api_key}",
  ]

  ports {
    internal = 80
    external = 80
  }

  ports {
    internal = 443
    external = 443
  }

  ports {
    internal = 8080
    external = 8080
    ip       = "127.0.0.1"
  }

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
    read_only      = true
  }

  volumes {
    volume_name    = docker_volume.traefik_letsencrypt.name
    container_path = "/letsencrypt"
  }

  networks_advanced {
    name = docker_network.proxy_tier.name
  }

  labels {
    label = "traefik.enable"
    value = "false"
  }
}

# ── Redis ─────────────────────────────────────────────────────────────────────
# DB 0: oauth2-proxy sessions; DB 1: FastAPI; DB 2: bridge pub/sub

resource "docker_container" "redis" {
  name    = "${local.prefix}redis"
  image   = "redis:${var.redis_version}"
  restart = "always"

  volumes {
    volume_name    = docker_volume.redis_data.name
    container_path = "/data"
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["redis"]
  }
}

# ── NanoMQ ────────────────────────────────────────────────────────────────────

resource "docker_container" "nanomq" {
  name    = "${local.prefix}nanomq"
  image   = "emqx/nanomq:${var.nanomq_version}"
  restart = "always"

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["nanomq"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["nanomq"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  # TCP router for TLS MQTT (SNI routing on port 8883)
  labels {
    label = "traefik.tcp.routers.${local.prefix}mqtt.rule"
    value = "HostSNI(`${local.mqtt_fqdn}`)"
  }

  labels {
    label = "traefik.tcp.routers.${local.prefix}mqtt.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.tcp.routers.${local.prefix}mqtt.tls"
    value = "true"
  }

  labels {
    label = "traefik.tcp.routers.${local.prefix}mqtt.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.tcp.routers.${local.prefix}mqtt.service"
    value = "${local.prefix}mqtt-svc"
  }

  labels {
    label = "traefik.tcp.services.${local.prefix}mqtt-svc.loadbalancer.server.port"
    value = "1883"
  }

  # HTTP router for WebSocket MQTT
  labels {
    label = "traefik.http.routers.${local.prefix}mqtt-ws.rule"
    value = "Host(`${local.mqtt_ws_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}mqtt-ws.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}mqtt-ws.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}mqtt-ws.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.services.${local.prefix}mqtt-ws.loadbalancer.server.port"
    value = "8083"
  }
}
