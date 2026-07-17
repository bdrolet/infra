# Cloud SQL instance shared by inbox (database "app") and tasks (database
# "tasks"). This state owns the instance; each app repo adds its own database +
# user via `data "google_sql_database_instance"`. The instance is the billable
# unit — a database on an existing instance costs nothing.
#
# Copied verbatim from the inbox repo's former cloudsql.tf so the post-import
# plan is a no-op. `deletion_protection` stays on. (The former
# `depends_on = [google_project_service.apis]` is dropped: API enablement still
# lives in the inbox root and the APIs are already enabled — depends_on is not a
# resource attribute, so its removal doesn't change the plan.)
resource "google_sql_database_instance" "inbox" {
  name             = "inbox"
  database_version = "POSTGRES_16"
  region           = var.region

  deletion_protection = true

  settings {
    tier = "db-f1-micro"

    disk_size = 10
    disk_type = "PD_SSD"

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }

    ip_configuration {
      ipv4_enabled = true
    }
  }
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL instance connection name — consumed as CLOUD_SQL_CONNECTION_NAME by inbox/tasks CFs"
  value       = google_sql_database_instance.inbox.connection_name
}
