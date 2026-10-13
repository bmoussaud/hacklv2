#!/bin/sh
set -eu
umask 077

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:=5432}"
: "${PGSSLMODE:=verify-full}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is required}"
: "${STORAGE_CONTAINER:?STORAGE_CONTAINER is required}"
: "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required for managed identity login}"

export PGPORT
export PGSSLMODE
az login --identity --client-id "$AZURE_CLIENT_ID" --allow-no-subscriptions --output none
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
random_suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

dump="$workdir/${PGDATABASE}-${timestamp}.dump"
pg_dump --no-password --format=custom --no-owner --no-acl \
  --file="$dump" --host="$PGHOST" --port="$PGPORT" \
  --username="$PGUSER" "$PGDATABASE"

checksum="$(sha256sum "$dump" | cut -d ' ' -f 1)"
blob_name="postgres/${PGDATABASE}/${timestamp}-${random_suffix}.dump"
metadata="sha256=${checksum}"

az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$STORAGE_CONTAINER" \
  --name "$blob_name" \
  --file "$dump" \
  --metadata "$metadata" \
  --auth-mode login \
  --only-show-errors \
  --output none

printf 'Uploaded blob %s (sha256 %s)\n' "$blob_name" "$checksum"
