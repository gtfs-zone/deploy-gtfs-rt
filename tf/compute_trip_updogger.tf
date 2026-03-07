# ── trip-updogger ─────────────────────────────────────────────────────────────

resource "docker_container" "trip_updogger" {
  name    = "${local.prefix}trip-updogger"
  image   = "${local.registry}/gtfs.zone/trip-updogger:${var.trip_updogger_tag}"
  restart = "always"

  env = [
    "MQTT_BROKER=tcp://nanomq:1883",
    "REDIS_URL=redis://redis:6379/1",
    "GTFS_FEED_URLS_ENDPOINT=http://gtfs-api:8000/feed_urls",
  ]

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["trip-updogger"]
  }

  depends_on = [
    docker_container.nanomq,
    docker_container.redis,
    docker_container.rt_api_public,
  ]
}
