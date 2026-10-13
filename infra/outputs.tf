output "resource_group_name" {
  value       = azurerm_resource_group.main.name
  description = "Resource group hosting the hackathon environment."
}

output "container_registry_name" {
  value       = azurerm_container_registry.main.name
  description = "ACR name for `az acr login` and image publication."
}

output "container_registry_login_server" {
  value       = azurerm_container_registry.main.login_server
  description = "ACR login server."
}

output "container_app_name" {
  value       = one(azurerm_container_app.inventory[*].name)
  description = "Container App name, null until deploy_application is enabled."
}

output "container_app_url" {
  value       = one(azurerm_container_app.inventory[*].latest_revision_fqdn)
  description = "Container App hostname, null until the app is deployed."
}

output "postgres_fqdn" {
  value       = azurerm_postgresql_flexible_server.main.fqdn
  description = "Private PostgreSQL FQDN resolvable from the Container Apps VNet."
}

output "storage_account_name" {
  value       = azurerm_storage_account.backup.name
  description = "Private Blob Storage account used for database backups."
}

output "backup_container_name" {
  value       = azurerm_storage_container.backup.name
  description = "Private backup blob container."
}

output "backup_identity_client_id" {
  value       = azurerm_user_assigned_identity.backup.client_id
  description = "User-assigned managed identity client ID used by the scheduled backup job."
}

output "restore_identity_principal_id" {
  value       = azurerm_user_assigned_identity.restore.principal_id
  description = "Separate reader identity for authorized isolated restore operations."
}

output "database_init_job_name" {
  value       = one(azurerm_container_app_job.db_init[*].name)
  description = "One-off database initialization job name, null until enabled."
}

output "backup_job_name" {
  value       = one(azurerm_container_app_job.backup[*].name)
  description = "Weekly Azure Blob backup job name, null until enabled."
}

output "restore_job_name" {
  value       = one(azurerm_container_app_job.restore[*].name)
  description = "Manual verified restore job name, null until enabled."
}
