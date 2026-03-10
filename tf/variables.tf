# All input variables in alphabetical order.

# ── Required ────────────────────────────────────────────────────────────────

variable "domain" {
  type        = string
  description = "Base domain (e.g. \"gtfs.zone\") used to build all FQDNs"
}

variable "server_ip" {
  type        = string
  description = "Public IP address of the host server (A record target)"
}

# ── Optional infrastructure ──────────────────────────────────────────────────

variable "docker_host" {
  type        = string
  description = "Remote Docker daemon URI (e.g. ssh://myserver). Unset = local socket."
  default     = null
}

variable "name_prefix" {
  type        = string
  description = "Prepended to container/volume/network names. Leave empty for no prefix."
  default     = ""
}

# ── OAuth connector credentials ───────────────────────────────────────────────
# Each provider block is optional — omit (or set to null) to disable that connector.

variable "github_oauth" {
  type = object({
    client_id     = string
    client_secret = string
  })
  description = "GitHub OAuth app credentials for Dex connector. Omit to disable."
  default     = null
  nullable    = true
  sensitive   = true
}

variable "gitlab_oauth" {
  type = object({
    client_id     = string
    client_secret = string
    base_url      = optional(string, "https://gitlab.com")
    groups        = optional(list(string), [])
  })
  description = "GitLab OAuth app credentials for Dex connector. Omit to disable."
  default     = null
  nullable    = true
  sensitive   = true
}

variable "google_oauth" {
  type = object({
    client_id      = string
    client_secret  = string
    hosted_domains = optional(list(string), [])
  })
  description = "Google OAuth credentials for Dex connector. Omit to disable."
  default     = null
  nullable    = true
  sensitive   = true
}

# ── DNS credentials ──────────────────────────────────────────────────────────

variable "porkbun_api_key" {
  type      = string
  sensitive = true
}

variable "porkbun_secret_api_key" {
  type      = string
  sensitive = true
}

# ── Private registry credentials ──────────────────────────────────────────────

variable "registry_username" {
  type        = string
  description = "Username for the private container registry at git.kcfam.us"
  default     = null
  nullable    = true
}

variable "registry_password" {
  type        = string
  description = "Password/token for the private container registry at git.kcfam.us"
  sensitive   = true
  default     = null
  nullable    = true
}

# ── Subdomain overrides ───────────────────────────────────────────────────────

variable "auth_subdomain" {
  type    = string
  default = "auth"
}

variable "dex_subdomain" {
  type    = string
  default = "dex"
}

variable "api_subdomain" {
  type    = string
  default = "rt"
}

variable "api_admin_subdomain" {
  type    = string
  default = "manage.rt"
}

variable "uptime_subdomain" {
  type    = string
  default = "uptime"
}

variable "status_subdomain" {
  type    = string
  default = "status"
}

variable "mqtt_subdomain" {
  type    = string
  default = "mqtt"
}

variable "mqtt_ws_subdomain" {
  type    = string
  default = "ws.mqtt"
}

# ── Image versions ────────────────────────────────────────────────────────────

variable "traefik_version" {
  type    = string
  default = "v3.6"
}

variable "oauth2_proxy_version" {
  type    = string
  default = "latest"
}

variable "dex_version" {
  type    = string
  default = "latest"
}

variable "redis_version" {
  type    = string
  default = "8.6-alpine"
}

variable "postgres_version" {
  type    = string
  default = "18.3-alpine"
}

variable "nanomq_version" {
  type    = string
  default = "latest"
}

variable "uptime_kuma_version" {
  type    = string
  default = "latest"
}

variable "redis_gtfs_rt_api_tag" {
  type    = string
  default = "latest"
}

variable "vehicle_poser_tag" {
  type    = string
  default = "latest"
}

variable "trip_updogger_tag" {
  type    = string
  default = "latest"
}

variable "schedule_foamer_tag" {
  type    = string
  default = "latest"
}

# ── Celery ───────────────────────────────────────────────────────────────────

variable "celery_worker_concurrency" {
  type        = number
  default     = 2
  description = "Number of Celery worker processes (concurrency). Lower = less RAM, fewer parallel feed loads."
}

variable "celery_max_tasks_per_child" {
  type        = number
  default     = 10
  description = "Celery worker processes are recycled after this many tasks, preventing memory growth."
}

# ── External Traefik ──────────────────────────────────────────────────────────

variable "use_external_traefik" {
  type        = bool
  description = "When true, skip deploying Traefik and attach containers to an existing proxy network."
  default     = false
}

variable "external_traefik_network" {
  type        = string
  description = "Name of the external Docker proxy network (required when use_external_traefik = true)."
  default     = null
  nullable    = true
  validation {
    condition     = !var.use_external_traefik || var.external_traefik_network != null
    error_message = "external_traefik_network is required when use_external_traefik = true."
  }
}

variable "traefik_cert_resolver" {
  type        = string
  description = "Name of the cert resolver on the active Traefik instance."
  default     = "letsencrypt"
}
