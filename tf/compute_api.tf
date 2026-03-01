# ── FastAPI backend (redis-gtfs-rt-api) ───────────────────────────────────────

resource "docker_container" "fastapi" {
  name    = "${local.prefix}redis-gtfs-rt-api"
  image   = "${local.registry}/gtfs.zone/redis-gtfs-rt-api:${var.redis_gtfs_rt_api_tag}"
  restart = "always"

  env = [
    "REDIS_URL=redis://redis:6379/1",
    "DATABASE_URL=postgresql://fastapi:${random_password.postgres_fastapi.result}@postgres:5432/fastapi",
    "SESSION_SECRET_KEY=${random_password.fastapi_session_secret.result}",
  ]

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["redis-gtfs-rt-api"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["redis-gtfs-rt-api"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}api.rule"
    value = "Host(`${local.api_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}api.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}api.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}api.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.routers.${local.prefix}api.middlewares"
    value = "${local.prefix}oauth2-proxy@docker"
  }

  labels {
    label = "traefik.http.services.${local.prefix}api.loadbalancer.server.port"
    value = "8000"
  }

  depends_on = [
    docker_container.redis,
    docker_container.postgres_init,
    docker_container.oauth2_proxy,
  ]
}
