# All sensitive credentials are generated here — zero secrets in tfvars.

resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "random_password" "postgres_dex" {
  length  = 32
  special = false
}

resource "random_password" "postgres_rt_api" {
  length  = 32
  special = false
}

resource "random_password" "dex_oauth2_proxy_secret" {
  length  = 32
  special = false
}

resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

resource "random_password" "rt_api_session_secret" {
  length  = 64
  special = false
}
