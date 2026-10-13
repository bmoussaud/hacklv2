#!/bin/sh
set -eu
umask 077

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:=5432}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${PGSSLMODE:=verify-full}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"
: "${STORAGE_CONTAINER:?STORAGE_CONTAINER is required}"
: "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required for managed identity login}"
: "${BLOB_NAME:?BLOB_NAME must name an existing verified backup blob}"

export PGPORT
export PGSSLMODE
az login --identity --client-id "$AZURE_CLIENT_ID" --allow-no-subscriptions --output none

expected_sha="$(
  az storage blob show \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$STORAGE_CONTAINER" \
    --name "$BLOB_NAME" \
    --query metadata.sha256 \
    --auth-mode login \
    --output tsv
)"
case "$expected_sha" in
  *[!0-9a-f]*|'') echo "Backup blob does not contain valid SHA-256 metadata." >&2; exit 1 ;;
esac
[ "${#expected_sha}" -eq 64 ] || { echo "Backup blob SHA-256 metadata is malformed." >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT HUP INT TERM
dump="$workdir/restore.dump"
az storage blob download \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$STORAGE_CONTAINER" \
  --name "$BLOB_NAME" \
  --file "$dump" \
  --auth-mode login \
  --only-show-errors \
  --output none

actual_sha="$(sha256sum "$dump" | cut -d ' ' -f 1)"
[ "$actual_sha" = "$expected_sha" ] || {
  echo "Backup checksum mismatch; refusing to restore." >&2
  exit 1
}

restore_database="inventory_restore_$(date -u +%Y%m%d%H%M%S)"
createdb --no-password --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" "$restore_database"
pg_restore --no-password --single-transaction --no-owner --no-acl \
  --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" \
  --dbname="$restore_database" "$dump"

row_count="$(psql --no-password --no-psqlrc --tuples-only --no-align \
  --host="$PGHOST" --port="$PGPORT" --username="$PGUSER" \
  --dbname="$restore_database" --command='SELECT count(*) FROM public.inventory')"
printf 'Restored verified blob %s to isolated database %s (%s inventory rows; sha256 %s)\n' \
  "$BLOB_NAME" "$restore_database" "$row_count" "$actual_sha"
