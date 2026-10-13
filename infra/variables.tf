variable "project_name" {
  type        = string
  description = "Short lowercase resource prefix used to name this hackathon deployment."
  default     = "last-harvest"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.project_name))
    error_message = "project_name must be 3-20 lowercase letters, digits, or hyphens and start with a letter."
  }
}

variable "location" {
  type        = string
  description = "Approved Azure region for the deployment."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all supported resources."
  default     = {}
}

variable "postgres_admin_username" {
  type        = string
  description = "PostgreSQL bootstrap administrator login."
  sensitive   = true
}

variable "postgres_admin_password" {
  type        = string
  description = "PostgreSQL bootstrap administrator password."
  sensitive   = true
}

variable "app_db_password" {
  type        = string
  description = "Password for the restricted inventory application role."
  sensitive   = true
}

variable "backup_db_password" {
  type        = string
  description = "Password for the read-only backup role."
  sensitive   = true
}

variable "allowed_users" {
  type        = list(string)
  description = "Exact Entra user email addresses allowed to use the application."

  validation {
    condition     = length(var.allowed_users) > 0 && alltrue([for email in var.allowed_users : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email))])
    error_message = "At least one valid email address must be allow-listed."
  }
}

variable "app_image" {
  type        = string
  description = "Immutable ACR image reference for the inventory application."
  default     = ""
}

variable "backup_image" {
  type        = string
  description = "Immutable ACR image reference for the PostgreSQL-to-Blob backup tool."
  default     = ""
}

variable "db_init_image" {
  type        = string
  description = "Immutable ACR image reference containing init.sql and database role bootstrap."
  default     = ""
}

variable "image_publisher_object_id" {
  type        = string
  description = "Optional principal object ID granted AcrPush; defaults to the authenticated Terraform principal."
  default     = ""

  validation {
    condition     = var.image_publisher_object_id == "" || can(regex("^[0-9a-fA-F-]{36}$", var.image_publisher_object_id))
    error_message = "image_publisher_object_id must be empty or a UUID."
  }
}

variable "deploy_application" {
  type        = bool
  description = "Create the application only after its immutable image is in ACR."
  default     = false
}

variable "public_ingress_enabled" {
  type        = bool
  description = "Publish authenticated HTTPS ingress; enable only after Entra auth is configured."
  default     = false
}

variable "entra_auth_configured" {
  type        = bool
  description = "Set only after Container Apps Entra Easy Auth is configured for this app."
  default     = false
}

variable "deploy_backup_job" {
  type        = bool
  description = "Create the scheduled weekly backup job after its immutable image is in ACR."
  default     = false
}

variable "deploy_db_init_job" {
  type        = bool
  description = "Create a manually triggered job for synthetic schema and role bootstrap."
  default     = false
}

variable "deploy_restore_job" {
  type        = bool
  description = "Create a manually triggered job to checksum-verify and restore a Blob backup into a new database."
  default     = false
}

variable "backup_schedule_utc" {
  type        = string
  description = "Five-field UTC cron schedule for the weekly database backup."
  default     = "0 2 * * 0"

  validation {
    condition     = can(regex("^[0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+ [0-9*/,-]+$", var.backup_schedule_utc))
    error_message = "backup_schedule_utc must be a five-field cron expression."
  }
}

variable "backup_retention_days" {
  type        = number
  description = "Blob retention duration before automatic deletion."
  default     = 90

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 365
    error_message = "backup_retention_days must be between 7 and 365 days."
  }
}
