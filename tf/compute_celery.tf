# ── Celery workers (schedule-foamer) ─────────────────────────────────────────

locals {
  schedule_foamer_image = "${local.registry}/gtfs.zone/schedule-foamer:${var.schedule_foamer_tag}"
  schedule_foamer_env = [
    "DATABASE_URL=postgresql+psycopg2://rt_api:${random_password.postgres_rt_api.result}@postgres:5432/rt_api",
    "CELERY_BROKER_URL=redis://redis:6379/3",
    "CELERY_RESULT_BACKEND=redis://redis:6379/4",
    "CELERY_WORKER_CONCURRENCY=${var.celery_worker_concurrency}",
    "CELERY_MAX_TASKS_PER_CHILD=${var.celery_max_tasks_per_child}",
  ]
}

# Worker: executes feed download/parse tasks
resource "docker_container" "celery_worker" {
  name    = "${local.prefix}celery-worker"
  image   = local.schedule_foamer_image
  restart = "always"
  command = ["celery", "-A", "schedule_foamer.celery_app", "worker", "-l", "info"]

  env = local.schedule_foamer_env

  networks_advanced {
    name = docker_network.internal.name
  }

  depends_on = [
    docker_container.redis,
    docker_container.rt_api_migrate,
  ]
}

# Beat: periodic scheduler — enqueues stale/failed feeds every minute
resource "docker_container" "celery_beat" {
  name    = "${local.prefix}celery-beat"
  image   = local.schedule_foamer_image
  restart = "always"
  command = ["celery", "-A", "schedule_foamer.celery_app", "beat", "-l", "info"]

  env = local.schedule_foamer_env

  networks_advanced {
    name = docker_network.internal.name
  }

  depends_on = [docker_container.redis]
}
