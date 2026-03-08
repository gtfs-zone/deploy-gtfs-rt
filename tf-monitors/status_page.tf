resource "uptimekuma_status_page" "main" {
  slug        = "status"
  title       = "GTFS-RT Services Status"
  description = "Live status for all GTFS-RT services"
  published   = true

  theme     = "auto"
  show_tags = false

  domain_name_list = [
    "status.${var.domain}",
  ]

  public_group_list = [

    # ───────────────── Public Services ────────────────────
    {
      name   = "Public Services"
      weight = 1

      monitor_list = [
        { id = uptimekuma_monitor_http.api_external.id, send_url = true },
      ]
    },

    # ───────────────── Infrastructure ─────────────────────
    {
      name   = "Infrastructure"
      weight = 2

      monitor_list = [
        { id = uptimekuma_monitor_tcp_port.traefik_http.id },
        { id = uptimekuma_monitor_tcp_port.traefik_https.id },
        { id = uptimekuma_monitor_tcp_port.postgres.id },
        { id = uptimekuma_monitor_tcp_port.redis.id },
      ]
    },

    # ───────────────── Auth ───────────────────────────────
    {
      name   = "Auth"
      weight = 3

      monitor_list = [
        { id = uptimekuma_monitor_http.oauth2_proxy_internal.id },
        { id = uptimekuma_monitor_docker.oauth2_proxy.id },
        { id = uptimekuma_monitor_docker.dex.id },
      ]
    },

    # ───────────────── Application ────────────────────────
    {
      name   = "Application"
      weight = 4

      monitor_list = [
        { id = uptimekuma_monitor_http.rt_api_internal.id },
        { id = uptimekuma_monitor_docker.rt_api.id },
        { id = uptimekuma_monitor_http.rt_api_admin_internal.id },
        { id = uptimekuma_monitor_docker.rt_api_admin.id },
        { id = uptimekuma_monitor_docker.bridge.id },
        { id = uptimekuma_monitor_docker.trip_updogger.id },
        { id = uptimekuma_monitor_docker.celery_worker.id },
        { id = uptimekuma_monitor_docker.celery_beat.id },
      ]
    },

    # ───────────────── MQTT ───────────────────────────────
    {
      name   = "MQTT"
      weight = 5

      monitor_list = [
        { id = uptimekuma_monitor_docker.nanomq.id },
        { id = uptimekuma_monitor_tcp_port.nanomq_mqtt.id },
        { id = uptimekuma_monitor_tcp_port.nanomq_ws.id },
      ]
    },

    # ───────────────── Monitoring Stack ───────────────────
    {
      name   = "Monitoring"
      weight = 6

      monitor_list = [
        { id = uptimekuma_monitor_docker.uptime_kuma.id },
      ]
    },

  ]
}
