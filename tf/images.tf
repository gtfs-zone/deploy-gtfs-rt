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

resource "docker_image" "prometheus" {
  name         = "kcfam/prometheus:local"
  keep_locally = true

  build {
    context = "${path.root}/../prometheus"
    build_args = {
      PROMETHEUS_VERSION = var.prometheus_version
    }
  }

  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset("${path.root}/../prometheus", "**") : filesha1("${path.root}/../prometheus/${f}")]))
  }
}

resource "docker_image" "grafana" {
  name         = "kcfam/grafana:local"
  keep_locally = true

  build {
    context = "${path.root}/../grafana"
    build_args = {
      GRAFANA_VERSION = var.grafana_version
    }
  }

  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset("${path.root}/../grafana", "**") : filesha1("${path.root}/../grafana/${f}")]))
  }
}
