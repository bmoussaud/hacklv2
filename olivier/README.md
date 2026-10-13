# Operation Last Harvest - synthetic handover

These files are generated hackathon fixtures, **not recovered Louis Vuitton
source code or production data**. They provide the four artifacts described in
the brief: `index.php`, `config.php`, `db_connect.php`, and `init.sql`, all in
the dedicated `olivier` folder.

The application lists inventory and lets a local operator update a stock
quantity. Updates use parameterized SQL, bounded integer validation, and a
session-backed CSRF token. Output is HTML-escaped. Database failures are logged
and return HTTP 503 without exposing credentials.

## Run with Docker Compose

Install Docker with Compose support. From the repository root, copy the example
configuration and set `DB_PASSWORD` in `.env` to a nonempty local password:

```powershell
Copy-Item .\.env.example .\.env
```

Set all three password fields to different, nonempty local values. `DB_PASSWORD`
is used only by PostgreSQL and the bootstrap task; `APP_DB_PASSWORD` is the
restricted app role; `BACKUP_DB_PASSWORD` is read-only. `.env` is ignored by Git.
`APP_PORT` defaults to `8080`; change it if that host port is in use.
Start the stack:

```powershell
docker compose up --build --wait
```

Open `http://127.0.0.1:8080/index.php` (or the chosen `APP_PORT`). Compose builds
Apache/PHP with the PostgreSQL extension, waits for PostgreSQL to become healthy,
runs the role bootstrap, and initializes a fresh database with all 108 rows from
`init.sql`. The application uses a restricted PostgreSQL role and Apache runs as
non-root on port 8080. Only the app port is published, on localhost; PostgreSQL
and the admin/bootstrap credentials are isolated to the Compose network.

```powershell
docker compose ps
docker compose logs app database
docker compose down
```

`down` preserves the named database volume and stock changes. SQL initialization
runs only when that volume is empty. To apply the idempotent seed script to an
existing database:

```powershell
docker compose exec database psql -U postgres -d inventory -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/01-inventory.sql
```

**Destructive reset:** `docker compose down --volumes` deletes this stack's local
inventory data. Use it only when intentionally starting over, then run the
startup command again. Changing `DB_PASSWORD` in `.env` does not change the
password of an already initialized database.

This stack is for local hackathon development: it uses unencrypted database traffic
and synthetic identity headers when `AUTH_REQUIRED`
is enabled for integration tests. Cloud ingress must be configured with Container
Apps Entra Easy Auth; the application allowlist expects the authenticated
`X-MS-CLIENT-PRINCIPAL` header from that trusted ingress. Direct clients must not
be able to reach the app container in production. Cloud deployment uses secure
cookies, verified PostgreSQL TLS, a restricted app role, and a separate
read-only backup role. Azure and Entra authentication setup is documented in the
repository root `README.md`.

## Run without Docker

Use PHP 8.2 or newer with `pdo_pgsql` and sessions, plus PostgreSQL 15 or newer.
Supply these environment variables to the PHP process:

| Variable | Meaning |
| --- | --- |
| `DB_HOST` | PostgreSQL hostname |
| `DB_PORT` | PostgreSQL port; defaults to `5432` |
| `DB_NAME` | Existing database name |
| `DB_USER` | Application database role |
| `DB_PASSWORD` | Application database password |
| `DB_SSLMODE` | `require` (default), `verify-ca`, `verify-full`, or `disable` for isolated local development |

Use certificate verification for the later cloud deployment. Keep credentials
outside the repository and container image. Environment files are not loaded
automatically.

Run these commands from the repository root. Create a local database and
initialize it using a schema-owning role:

```powershell
psql -h localhost -U <schema-owner> -d <database-name> -v ON_ERROR_STOP=1 -f .\olivier\init.sql
```

The script is transactional, never drops tables, and does not overwrite existing
stock quantities when rerun. It inserts eight base products and uses PostgreSQL
`generate_series` to create 100 additional inventory lots, for **108 rows** in a
fresh database. Generated SKUs and quantities are deterministic, with quantities
between 0 and 100. All rows are synthetic. This is not a production migration or
a dump of the legacy database.

Use a separate application role with `SELECT` on `inventory` and `UPDATE` on
its `quantity` and `updated_at` columns. Supply the environment variables above,
then start a localhost-only development server:

```powershell
php -S 127.0.0.1:8080 -t .\olivier
```

Open `http://127.0.0.1:8080/index.php`. Confirm that all 108 inventory rows appear,
update a quantity, reload to confirm persistence, and restore the original value.
An invalid quantity must be rejected; a missing or incorrect CSRF token must
return HTTP 403. Check server logs if the application returns HTTP 503.

## Boundaries

This handover intentionally has no authentication: run it locally only.
The local Compose default allows access only through localhost; enable
`AUTH_REQUIRED=true` and configure `ALLOWED_USERS` to exercise the allowlist.
Before public deployment, configure Azure Container Apps Entra Easy Auth and
verify ingress/network access controls. Terraform, Azure deployment,
backup/restore, weekly Azure Blob export, CI/CD, and the
nightly database reader remain separate implementation tasks. No credentials,
old-server access, or real migration evidence are supplied by these fixtures.
