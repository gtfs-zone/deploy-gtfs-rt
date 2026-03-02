# ── FastAPI backend (redis-gtfs-rt-api) ───────────────────────────────────────

locals {
  fastapi_image = "${local.registry}/gtfs.zone/redis-gtfs-rt-api:${var.redis_gtfs_rt_api_tag}"
  fastapi_env = [
    "REDIS_URL=redis://redis:6379/1",
    "DATABASE_URL=postgresql://fastapi:${random_password.postgres_fastapi.result}@postgres:5432/fastapi",
    "SESSION_SECRET_KEY=${random_password.fastapi_session_secret.result}",
  ]
}

# ── Init container — runs Alembic migrations then exits ───────────────────────
# Runs once (restart=no). Re-running is safe: alembic tracks applied versions.

resource "docker_container" "fastapi_migrate" {
  name     = "${local.prefix}gtfs-migrate"
  image    = local.fastapi_image
  restart  = "no"
  must_run = false

  command = ["alembic", "upgrade", "head"]

  env = local.fastapi_env

  networks_advanced {
    name = docker_network.internal.name
  }

  depends_on = [docker_container.postgres_init]
}

resource "docker_container" "fastapi_public" {
  name    = "${local.prefix}gtfs-api"
  image   = local.fastapi_image
  restart = "always"
  command = ["fastapi", "run", "src/app/main.py", "--port", "8000"]

  env = local.fastapi_env

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["gtfs-api"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["gtfs-api"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-public.rule"
    value = "Host(`${local.api_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-public.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-public.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-public.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-public.service"
    value = "${local.prefix}rt-api-public"
  }

  labels {
    label = "traefik.http.services.${local.prefix}rt-api-public.loadbalancer.server.port"
    value = "8000"
  }

  depends_on = [
    docker_container.redis,
    docker_container.fastapi_migrate,
  ]
}

resource "docker_container" "fastapi_admin" {
  name    = "${local.prefix}gtfs-manager"
  image   = local.fastapi_image
  restart = "always"
  command = ["fastapi", "run", "src/app/admin_main.py", "--port", "8001", "--proxy-headers", "--forwarded-allow-ips=*"]

  env = local.fastapi_env

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["gtfs-manager"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["gtfs-manager"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-admin.rule"
    value = "Host(`${local.api_admin_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-admin.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-admin.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-admin.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-admin.middlewares"
    value = "${local.prefix}oauth2-errors@docker,${local.prefix}oauth2-proxy@docker"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}rt-api-admin.service"
    value = "${local.prefix}rt-api-admin"
  }

  labels {
    label = "traefik.http.services.${local.prefix}rt-api-admin.loadbalancer.server.port"
    value = "8001"
  }

  depends_on = [
    docker_container.redis,
    docker_container.fastapi_migrate,
    docker_container.oauth2_proxy,
  ]
}
