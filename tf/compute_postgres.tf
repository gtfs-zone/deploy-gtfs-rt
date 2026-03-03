# ── Postgres ──────────────────────────────────────────────────────────────────

resource "docker_container" "postgres" {
  name    = "${local.prefix}postgres"
  image   = "postgres:${var.postgres_version}"
  restart = "always"

  env = [
    "POSTGRES_PASSWORD=${random_password.postgres_admin.result}",
  ]

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql"
  }

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["postgres"]
  }
}

# ── Init container — creates per-service users and databases ──────────────────
# Runs once (restart=no). Re-running is safe: CREATE IF NOT EXISTS semantics.

resource "docker_container" "postgres_init" {
  name      = "${local.prefix}postgres-init"
  image     = "postgres:${var.postgres_version}"
  restart   = "no"
  must_run  = false

  env = [
    "PGPASSWORD=${random_password.postgres_admin.result}",
  ]

  entrypoint = [
    "/bin/sh", "-c",
    <<-EOT
      until pg_isready -h postgres -U postgres; do sleep 2; done
psql -h postgres -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='dex'" | grep -q 1 || \
        psql -h postgres -U postgres -c "CREATE USER dex WITH PASSWORD '${random_password.postgres_dex.result}'"
      psql -h postgres -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='dex'" | grep -q 1 || \
        psql -h postgres -U postgres -c "CREATE DATABASE dex OWNER dex"
      psql -h postgres -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='rt_api'" | grep -q 1 || \
        psql -h postgres -U postgres -c "CREATE USER rt_api WITH PASSWORD '${random_password.postgres_rt_api.result}'"
      psql -h postgres -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='rt_api'" | grep -q 1 || \
        psql -h postgres -U postgres -c "CREATE DATABASE rt_api OWNER rt_api"
    EOT
  ]

  networks_advanced {
    name = docker_network.internal.name
  }

  depends_on = [docker_container.postgres]
}
