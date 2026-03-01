# ── Dex ───────────────────────────────────────────────────────────────────────

resource "docker_container" "dex" {
  name    = "${local.prefix}dex"
  image   = docker_image.dex.image_id
  restart = "always"

  command = ["dex", "serve", "/etc/dex/config.yaml"]

  env = [
    "DEX_ISSUER=https://${local.dex_fqdn}",
    "DEX_POSTGRES_PASSWORD=${random_password.postgres_dex.result}",
    "DEX_AUTHELIA_REDIRECT_URI=https://${local.auth_fqdn}/api/oidc/callback",
    "DEX_AUTHELIA_SECRET=${random_password.dex_authelia_secret.result}",
  ]

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["dex"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["dex"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}dex.rule"
    value = "Host(`${local.dex_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}dex.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}dex.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}dex.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.services.${local.prefix}dex.loadbalancer.server.port"
    value = "5556"
  }

  depends_on = [
    docker_container.postgres_init,
  ]
}

# ── Authelia ──────────────────────────────────────────────────────────────────

resource "docker_container" "authelia" {
  name    = "${local.prefix}authelia"
  image   = "authelia/authelia:${var.authelia_version}"
  restart = "always"

  env = [
    "AUTHELIA_SERVER_ADDRESS=tcp://0.0.0.0:9091",
    "AUTHELIA_SESSION_SECRET=${random_password.authelia_session_secret.result}",
    "AUTHELIA_SESSION_REDIS_HOST=redis",
    "AUTHELIA_SESSION_REDIS_PORT=6379",
    "AUTHELIA_SESSION_REDIS_DATABASE_INDEX=0",
    "AUTHELIA_STORAGE_POSTGRES_ADDRESS=tcp://postgres:5432",
    "AUTHELIA_STORAGE_POSTGRES_DATABASE=authelia",
    "AUTHELIA_STORAGE_POSTGRES_USERNAME=authelia",
    "AUTHELIA_STORAGE_POSTGRES_PASSWORD=${random_password.postgres_authelia.result}",
    "AUTHELIA_STORAGE_ENCRYPTION_KEY=${random_password.authelia_storage_key.result}",
    "AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=${random_password.authelia_jwt_secret.result}",
    "AUTHELIA_AUTHENTICATION_BACKEND_FILE_PATH=/config/users_database.yml",
    "AUTHELIA_ACCESS_CONTROL_DEFAULT_POLICY=one_factor",
    "AUTHELIA_NOTIFIER_FILESYSTEM_FILENAME=/config/notification.txt",
  ]

  volumes {
    volume_name    = docker_volume.authelia_data.name
    container_path = "/config"
  }

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["authelia"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["authelia"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}authelia.rule"
    value = "Host(`${local.auth_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}authelia.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}authelia.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}authelia.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.services.${local.prefix}authelia.loadbalancer.server.port"
    value = "9091"
  }

  # ForwardAuth middleware — referenced by other containers as ${local.prefix}authelia@docker
  labels {
    label = "traefik.http.middlewares.${local.prefix}authelia.forwardauth.address"
    value = "http://authelia:9091/api/authz/forward-auth"
  }

  labels {
    label = "traefik.http.middlewares.${local.prefix}authelia.forwardauth.trustForwardHeader"
    value = "true"
  }

  labels {
    label = "traefik.http.middlewares.${local.prefix}authelia.forwardauth.authResponseHeaders"
    value = "Remote-User,Remote-Groups,Remote-Name,Remote-Email"
  }

  depends_on = [
    docker_container.redis,
    docker_container.postgres_init,
    docker_container.authelia_config_init,
  ]
}

# ── Authelia config init ───────────────────────────────────────────────────────
# Runs once to write configuration.yml into the named volume.
# session.cookies cannot be set via environment variables in current Authelia.

resource "docker_container" "authelia_config_init" {
  name     = "${local.prefix}authelia-config-init"
  image    = "alpine:latest"
  restart  = "no"
  must_run = false

  entrypoint = ["/bin/sh", "-c", <<-EOT
    cat > /config/configuration.yml <<'AUTHELIA_CONFIG'
    session:
      cookies:
        - domain: '${var.domain}'
          authelia_url: 'https://${local.auth_fqdn}'
    AUTHELIA_CONFIG
  EOT
  ]

  volumes {
    volume_name    = docker_volume.authelia_data.name
    container_path = "/config"
  }
}
