# ── Dex ───────────────────────────────────────────────────────────────────────

resource "docker_container" "dex" {
  name    = "${local.prefix}dex"
  image   = docker_image.dex.image_id
  restart = "always"

  command = ["dex", "serve", "/etc/dex/config.yaml"]

  env = [
    "DEX_ISSUER=https://${local.dex_fqdn}",
    "DEX_POSTGRES_PASSWORD=${random_password.postgres_dex.result}",
    "DEX_GITHUB_CLIENT_ID=${var.github_client_id}",
    "DEX_GITHUB_CLIENT_SECRET=${var.github_client_secret}",
    "DEX_OAUTH2_PROXY_REDIRECT_URI=https://${local.auth_fqdn}/oauth2/callback",
    "DEX_OAUTH2_PROXY_SECRET=${random_password.dex_oauth2_proxy_secret.result}",
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

# ── oauth2-proxy ──────────────────────────────────────────────────────────────

resource "docker_container" "oauth2_proxy" {
  name    = "${local.prefix}oauth2-proxy"
  image   = "quay.io/oauth2-proxy/oauth2-proxy:${var.oauth2_proxy_version}"
  restart = "always"

  env = [
    "OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180",
    "OAUTH2_PROXY_PROVIDER=oidc",
    "OAUTH2_PROXY_OIDC_ISSUER_URL=https://${local.dex_fqdn}",
    "OAUTH2_PROXY_CLIENT_ID=oauth2-proxy",
    "OAUTH2_PROXY_CLIENT_SECRET=${random_password.dex_oauth2_proxy_secret.result}",
    "OAUTH2_PROXY_REDIRECT_URL=https://${local.auth_fqdn}/oauth2/callback",
    "OAUTH2_PROXY_COOKIE_SECRET=${random_password.oauth2_proxy_cookie_secret.result}",
    "OAUTH2_PROXY_COOKIE_DOMAINS=.${var.domain}",
    "OAUTH2_PROXY_WHITELIST_DOMAINS=.${var.domain}",
    "OAUTH2_PROXY_EMAIL_DOMAINS=*",
    "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true",
    "OAUTH2_PROXY_UPSTREAM=static://202",
    "OAUTH2_PROXY_SESSION_STORE_TYPE=redis",
    "OAUTH2_PROXY_REDIS_CONNECTION_URL=redis://redis:6379/0",
    "OAUTH2_PROXY_COOKIE_SECURE=true",
    "OAUTH2_PROXY_REVERSE_PROXY=true",
  ]

  networks_advanced {
    name    = local.proxy_network_name
    aliases = ["oauth2-proxy"]
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["oauth2-proxy"]
  }

  labels {
    label = "traefik.enable"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}oauth2-proxy.rule"
    value = "Host(`${local.auth_fqdn}`)"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}oauth2-proxy.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}oauth2-proxy.tls"
    value = "true"
  }

  labels {
    label = "traefik.http.routers.${local.prefix}oauth2-proxy.tls.certresolver"
    value = var.traefik_cert_resolver
  }

  labels {
    label = "traefik.http.services.${local.prefix}oauth2-proxy.loadbalancer.server.port"
    value = "4180"
  }

  # ForwardAuth middleware — referenced by other containers as ${local.prefix}oauth2-proxy@docker
  labels {
    label = "traefik.http.middlewares.${local.prefix}oauth2-proxy.forwardauth.address"
    value = "http://oauth2-proxy:4180"
  }

  labels {
    label = "traefik.http.middlewares.${local.prefix}oauth2-proxy.forwardauth.trustForwardHeader"
    value = "true"
  }

  labels {
    label = "traefik.http.middlewares.${local.prefix}oauth2-proxy.forwardauth.authResponseHeaders"
    value = "X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Access-Token"
  }

  depends_on = [
    docker_container.redis,
    docker_container.dex,
  ]
}
