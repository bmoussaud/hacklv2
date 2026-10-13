#!/bin/sh
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"

psql --no-psqlrc --set=ON_ERROR_STOP=1 --file=/opt/inventory/init.sql
/opt/inventory/bootstrap.sh
