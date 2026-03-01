# All named volumes. Labels are managed externally and ignored here to avoid forced replacements.

resource "docker_volume" "postgres_data" {
  name = "${local.prefix}postgres_data"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

resource "docker_volume" "redis_data" {
  name = "${local.prefix}redis_data"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

resource "docker_volume" "traefik_letsencrypt" {
  name = "${local.prefix}traefik_letsencrypt"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

resource "docker_volume" "authelia_data" {
  name = "${local.prefix}authelia_data"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

resource "docker_volume" "prometheus_data" {
  name = "${local.prefix}prometheus_data"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}

resource "docker_volume" "uptime_kuma_data" {
  name = "${local.prefix}uptime_kuma_data"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [labels]
  }
}
