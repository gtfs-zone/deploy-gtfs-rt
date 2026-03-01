# All sensitive credentials are generated here — zero secrets in tfvars.

resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "random_password" "postgres_authelia" {
  length  = 32
  special = false
}

resource "random_password" "postgres_dex" {
  length  = 32
  special = false
}

resource "random_password" "postgres_fastapi" {
  length  = 32
  special = false
}

resource "random_password" "authelia_jwt_secret" {
  length  = 64
  special = false
}

resource "random_password" "authelia_storage_key" {
  length  = 64
  special = false
}

resource "random_password" "authelia_session_secret" {
  length  = 64
  special = false
}

resource "random_password" "dex_authelia_secret" {
  length  = 32
  special = false
}

resource "random_password" "fastapi_session_secret" {
  length  = 64
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}
