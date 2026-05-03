# ── vehicle-poser ─────────────────────────────────────────────────────────────

resource "docker_container" "bridge" {
  name    = "${local.prefix}vehicle-poser"
  image   = "${local.registry}/gtfs.zone/vehicle-poser:${var.vehicle_poser_tag}"
  restart = "always"

  env = [
    "MQTT_BROKER=tcp://nanomq:1883",
    "MQTT_USERNAME=public",
    "MQTT_PASSWORD=public",
    "REDIS_URL=redis://redis:6379/1",
    "DATABASE_URL=postgresql://rt_api:${random_password.postgres_rt_api.result}@postgres:5432/rt_api",
  ]

  networks_advanced {
    name    = docker_network.internal.name
    aliases = ["vehicle-poser"]
  }

  depends_on = [
    docker_container.nanomq,
    docker_container.redis,
    docker_container.postgres_init,
  ]
}
