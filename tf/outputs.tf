output "postgres_admin_password" {
  description = "Generated Postgres superuser password"
  value       = random_password.postgres_admin.result
  sensitive   = true
}
