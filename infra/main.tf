locals {
  name                      = var.project_name
  image_publisher_object_id = var.image_publisher_object_id != "" ? var.image_publisher_object_id : data.azurerm_client_config.current.object_id
  tags = merge(var.tags, {
    application = "operation-last-harvest"
    environment = "hackathon"
    synthetic   = "true"
  })
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name}-logs"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_registry" "main" {
  name                          = "${replace(local.name, "-", "")}${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku                           = "Basic"
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "${local.name}-vnet"
  address_space       = ["10.42.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "container_apps" {
  name                 = "container-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.0.0/23"]
  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.2.0/24"]
  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = ["10.42.3.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${local.name}-postgres-dns"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "${local.name}-pg-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false
  administrator_login           = var.postgres_admin_username
  administrator_password        = var.postgres_admin_password
  storage_mb                    = 32768
  sku_name                      = "B_Standard_B1ms"
  backup_retention_days         = 14
  geo_redundant_backup_enabled  = false
  zone                          = "1"
  tags                          = local.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "inventory" {
  name      = "inventory"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_storage_account" "backup" {
  name                            = "last${random_string.suffix.result}backup"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  public_network_access_enabled   = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "backup" {
  name                  = "postgres-backups"
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "backup" {
  storage_account_id = azurerm_storage_account.backup.id
  rule {
    name    = "expire-postgres-backups"
    enabled = true
    filters {
      prefix_match = ["postgres/inventory/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.backup_retention_days
      }
    }
  }
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "${local.name}-blob-dns"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${local.name}-blob-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "${local.name}-blob-connection"
    private_connection_resource_id = azurerm_storage_account.backup.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
  tags = local.tags
}

resource "azurerm_container_app_environment" "main" {
  name                           = "${local.name}-aca"
  location                       = azurerm_resource_group.main.location
  resource_group_name            = azurerm_resource_group.main.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id       = azurerm_subnet.container_apps.id
  internal_load_balancer_enabled = false
  tags                           = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name}-app-id"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "backup" {
  name                = "${local.name}-backup-id"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "db_init" {
  name                = "${local.name}-init-id"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "restore" {
  name                = "${local.name}-restore-id"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.app.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "github_acr_push" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPush"
  principal_id                     = local.image_publisher_object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "backup_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.backup.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "db_init_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.db_init.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "restore_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.restore.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "backup_blob_write" {
  scope                            = "${azurerm_storage_account.backup.id}/blobServices/default/containers/${azurerm_storage_container.backup.name}"
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.backup.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "restore_blob_read" {
  scope                            = "${azurerm_storage_account.backup.id}/blobServices/default/containers/${azurerm_storage_container.backup.name}"
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_user_assigned_identity.restore.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_container_app" "inventory" {
  count                        = var.deploy_application ? 1 : 0
  name                         = "${local.name}-app"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  max_inactive_revisions       = 2
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  secret {
    name  = "db-password"
    value = var.app_db_password
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "inventory"
      image  = var.app_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "DB_HOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "DB_PORT"
        value = "5432"
      }
      env {
        name  = "DB_NAME"
        value = "inventory"
      }
      env {
        name  = "DB_USER"
        value = "inventory_app"
      }
      env {
        name        = "DB_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name  = "DB_SSLMODE"
        value = "verify-full"
      }
      env {
        name  = "PGSSLROOTCERT"
        value = "/etc/ssl/certs/ca-certificates.crt"
      }
      env {
        name  = "AUTH_REQUIRED"
        value = "true"
      }
      env {
        name  = "ALLOWED_USERS"
        value = join(",", var.allowed_users)
      }
      env {
        name  = "SESSION_COOKIE_SECURE"
        value = "true"
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health.php"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/ready.php"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }

  ingress {
    external_enabled           = var.public_ingress_enabled
    target_port                = 8080
    transport                  = "http"
    allow_insecure_connections = false
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  lifecycle {
    precondition {
      condition     = !var.public_ingress_enabled || var.entra_auth_configured
      error_message = "Do not enable public ingress until Entra Easy Auth is configured and tested."
    }
  }

  depends_on = [
    azurerm_role_assignment.app_acr_pull,
    azurerm_private_endpoint.blob,
    azurerm_storage_management_policy.backup
  ]
}

resource "azurerm_container_app_job" "backup" {
  count                        = var.deploy_backup_job ? 1 : 0
  name                         = "${local.name}-backup"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 1
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  schedule_trigger_config {
    cron_expression          = var.backup_schedule_utc
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.backup.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.backup.id
  }

  secret {
    name  = "backup-db-password"
    value = var.backup_db_password
  }

  template {
    container {
      name   = "postgres-backup"
      image  = var.backup_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "PGPORT"
        value = "5432"
      }
      env {
        name  = "PGDATABASE"
        value = "inventory"
      }
      env {
        name  = "PGUSER"
        value = "inventory_backup"
      }
      env {
        name        = "PGPASSWORD"
        secret_name = "backup-db-password"
      }
      env {
        name  = "PGSSLMODE"
        value = "verify-full"
      }
      env {
        name  = "PGSSLROOTCERT"
        value = "/etc/pki/tls/certs/ca-bundle.crt"
      }
      env {
        name  = "STORAGE_ACCOUNT"
        value = azurerm_storage_account.backup.name
      }
      env {
        name  = "STORAGE_CONTAINER"
        value = azurerm_storage_container.backup.name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.backup.client_id
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.backup_acr_pull,
    azurerm_role_assignment.backup_blob_write,
    azurerm_private_endpoint.blob,
    azurerm_private_dns_zone_virtual_network_link.blob
  ]
}

resource "azurerm_container_app_job" "db_init" {
  count                        = var.deploy_db_init_job ? 1 : 0
  name                         = "${local.name}-db-init"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 0
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.db_init.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.db_init.id
  }

  secret {
    name  = "postgres-admin-password"
    value = var.postgres_admin_password
  }
  secret {
    name  = "app-db-password"
    value = var.app_db_password
  }
  secret {
    name  = "backup-db-password"
    value = var.backup_db_password
  }

  template {
    container {
      name   = "database-initializer"
      image  = var.db_init_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "PGPORT"
        value = "5432"
      }
      env {
        name  = "PGDATABASE"
        value = "inventory"
      }
      env {
        name  = "PGUSER"
        value = var.postgres_admin_username
      }
      env {
        name        = "PGPASSWORD"
        secret_name = "postgres-admin-password"
      }
      env {
        name  = "PGSSLMODE"
        value = "verify-full"
      }
      env {
        name  = "PGSSLROOTCERT"
        value = "/etc/ssl/certs/ca-certificates.crt"
      }
      env {
        name  = "APP_DB_USER"
        value = "inventory_app"
      }
      env {
        name        = "APP_DB_PASSWORD"
        secret_name = "app-db-password"
      }
      env {
        name  = "BACKUP_DB_USER"
        value = "inventory_backup"
      }
      env {
        name        = "BACKUP_DB_PASSWORD"
        secret_name = "backup-db-password"
      }
    }
  }

  depends_on = [azurerm_role_assignment.db_init_acr_pull]
}

resource "azurerm_container_app_job" "restore" {
  count                        = var.deploy_restore_job ? 1 : 0
  name                         = "${local.name}-restore"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 0
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.restore.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.restore.id
  }

  secret {
    name  = "postgres-admin-password"
    value = var.postgres_admin_password
  }

  template {
    container {
      name    = "postgres-restore"
      image   = var.backup_image
      command = ["/usr/local/bin/restore.sh"]
      cpu     = 0.5
      memory  = "1Gi"

      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.main.fqdn
      }
      env {
        name  = "PGPORT"
        value = "5432"
      }
      env {
        name  = "PGUSER"
        value = var.postgres_admin_username
      }
      env {
        name        = "PGPASSWORD"
        secret_name = "postgres-admin-password"
      }
      env {
        name  = "PGSSLMODE"
        value = "verify-full"
      }
      env {
        name  = "PGSSLROOTCERT"
        value = "/etc/pki/tls/certs/ca-bundle.crt"
      }
      env {
        name  = "STORAGE_ACCOUNT"
        value = azurerm_storage_account.backup.name
      }
      env {
        name  = "STORAGE_CONTAINER"
        value = azurerm_storage_container.backup.name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.restore.client_id
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.restore_acr_pull,
    azurerm_role_assignment.restore_blob_read,
    azurerm_private_endpoint.blob,
    azurerm_private_dns_zone_virtual_network_link.blob
  ]
}
