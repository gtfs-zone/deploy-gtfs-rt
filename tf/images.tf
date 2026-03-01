resource "docker_image" "traefik" {
  name         = "kcfam/traefik:local"
  keep_locally = true

  build {
    context = "${path.root}/../traefik"
    build_args = {
      TRAEFIK_VERSION = var.traefik_version
    }
  }

  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset("${path.root}/../traefik", "**") : filesha1("${path.root}/../traefik/${f}")]))
  }
}

resource "docker_image" "dex" {
  name         = "kcfam/dex:local"
  keep_locally = true

  build {
    context = "${path.root}/../dex"
    build_args = {
      DEX_VERSION = var.dex_version
    }
  }

  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset("${path.root}/../dex", "**") : filesha1("${path.root}/../dex/${f}")]))
  }
}

