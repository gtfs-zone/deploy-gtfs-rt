# ── Uptime Kuma ───────────────────────────────────────────────────────────────

resource "docker_container" "uptime_kuma" {
  name    = "${local.prefix}uptime-kuma"
  image   = "louislam/uptime-kuma:${var.uptime_kuma_version}"
  restart = "always"

  volumes {
    volume_name    = docker_volume.uptime_kuma_data.name
    container_path = "/app/data"
  }

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
    read_only      = true
  }

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["uptime-kuma"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["uptime-kuma"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  # Authenticated uptime dashboard
  labels {
    label = "traefik.http.routers.${local.prefix}uptime.rule"
    value = "Host(`${local.uptime_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}uptime.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}uptime.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}uptime.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.services.${local.prefix}uptime.loadbalancer.server.port"
    value = "3001"
  }

  # Public status page (no auth middleware)
  labels {
    label = "traefik.http.routers.${local.prefix}status-page.rule"
    value = "Host(`${local.status_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}status-page.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}status-page.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}status-page.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.routers.${local.prefix}status-page.service"
    value = "${local.prefix}uptime"
  }
}
