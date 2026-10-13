#!/bin/sh
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${APP_DB_USER:?APP_DB_USER is required}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"
: "${BACKUP_DB_USER:?BACKUP_DB_USER is required}"
: "${BACKUP_DB_PASSWORD:?BACKUP_DB_PASSWORD is required}"

psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --set=app_user="$APP_DB_USER" \
  --set=app_password="$APP_DB_PASSWORD" \
  --set=backup_user="$BACKUP_DB_USER" \
  --set=backup_password="$BACKUP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'app_user'
)
\gexec

ALTER ROLE :"app_user" LOGIN PASSWORD :'app_password';
GRANT CONNECT ON DATABASE inventory TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
GRANT SELECT ON TABLE public.inventory TO :"app_user";
GRANT UPDATE (quantity, updated_at) ON TABLE public.inventory TO :"app_user";

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'backup_user', :'backup_password')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'backup_user'
)
\gexec

ALTER ROLE :"backup_user" LOGIN PASSWORD :'backup_password';
GRANT CONNECT ON DATABASE inventory TO :"backup_user";
GRANT USAGE ON SCHEMA public TO :"backup_user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"backup_user";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO :"backup_user";
SQL
