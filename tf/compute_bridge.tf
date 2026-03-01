# ── owntrack-redis-bridge ─────────────────────────────────────────────────────

resource "docker_container" "bridge" {
  name    = "${local.prefix}owntrack-redis-bridge"
  image   = "${local.registry}/gtfs.zone/owntrack-redis-bridge:${var.owntrack_redis_bridge_tag}"
  restart = "always"

  env = [
    "MQTT_BROKER=tcp://nanomq:1883",
    "REDIS_URL=redis://redis:6379/2",
  ]

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["owntrack-redis-bridge"]
  }

  depends_on = [
    docker_container.nanomq,
    docker_container.redis,
  ]
}
