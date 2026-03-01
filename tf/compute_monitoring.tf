# ── node-exporter ─────────────────────────────────────────────────────────────

resource "docker_container" "node_exporter" {
  name    = "${local.prefix}node-exporter"
  image   = "prom/node-exporter:${var.node_exporter_version}"
  restart = "always"

  command = [
    "--path.procfs=/host/proc",
    "--path.rootfs=/rootfs",
    "--path.sysfs=/host/sys",
    "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)",
  ]

  volumes {
    host_path      = "/proc"
    container_path = "/host/proc"
    read_only      = true
  }

  volumes {
    host_path      = "/sys"
    container_path = "/host/sys"
    read_only      = true
  }

  volumes {
    host_path      = "/"
    container_path = "/rootfs"
    read_only      = true
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["node-exporter"]
  }
}

# ── cAdvisor ──────────────────────────────────────────────────────────────────

resource "docker_container" "cadvisor" {
  name       = "${local.prefix}cadvisor"
  image      = "ghcr.io/google/cadvisor:${var.cadvisor_version}"
  restart    = "always"
  privileged = true

  volumes {
    host_path      = "/"
    container_path = "/rootfs"
    read_only      = true
  }

  volumes {
    host_path      = "/var/run"
    container_path = "/var/run"
    read_only      = true
  }

  volumes {
    host_path      = "/sys"
    container_path = "/sys"
    read_only      = true
  }

  volumes {
    host_path      = "/var/lib/docker"
    container_path = "/var/lib/docker"
    read_only      = true
  }

  volumes {
    host_path      = "/dev/disk"
    container_path = "/dev/disk"
    read_only      = true
  }

  devices {
    host_path      = "/dev/kmsg"
    container_path = "/dev/kmsg"
    permissions    = "rwm"
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["cadvisor"]
  }
}

# ── Prometheus ────────────────────────────────────────────────────────────────

resource "docker_container" "prometheus" {
  name    = "${local.prefix}prometheus"
  image   = docker_image.prometheus.image_id
  restart = "always"

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--web.console.libraries=/etc/prometheus/console_libraries",
    "--web.console.templates=/etc/prometheus/consoles",
    "--web.enable-lifecycle",
    "--storage.tsdb.retention.time=30d",
    "--query.lookback-delta=30s",
  ]

  volumes {
    volume_name    = docker_volume.prometheus_data.name
    container_path = "/prometheus"
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["prometheus"]
  }

  depends_on = [
    docker_container.node_exporter,
    docker_container.cadvisor,
  ]
}

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
