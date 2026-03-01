resource "docker_network" "proxy_tier" {
  name = "${local.prefix}proxy-tier"
}

resource "docker_network" "internal" {
  name = "${local.prefix}internal"
}
