variable "domain" {
  type        = string
  description = "Base domain (e.g. \"gtfs.example.com\") — must match the main tf/ stack"
}

variable "uptime_subdomain" {
  type        = string
  description = "Subdomain for Uptime Kuma (used to build the provider endpoint)"
  default     = "uptime"
}

variable "name_prefix" {
  type        = string
  description = "Container name prefix — must match the main tf/ stack (leave empty for none)"
  default     = ""
}

variable "api_subdomain" {
  type        = string
  description = "Subdomain for the public RT API — must match the main tf/ stack"
  default     = "rt"
}

variable "uptime_kuma_username" {
  type        = string
  description = "Uptime Kuma admin username"
  default     = "admin"
}

variable "uptime_kuma_password" {
  type        = string
  description = "Uptime Kuma admin password"
  sensitive   = true
}

variable "telegram_bot_token" {
  type        = string
  description = "Telegram bot token for Uptime Kuma notifications"
  sensitive   = true
}

variable "telegram_chat_id" {
  type        = string
  description = "Telegram chat ID to send notifications to"
}
