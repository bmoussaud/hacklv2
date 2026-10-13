# Operation Last Harvest - hackathon implementation

This repository contains a **synthetic** PHP/PostgreSQL inventory application,
not recovered Louis Vuitton source code or a production database. The current
local stack runs with Docker Compose and generated sample stock; no legacy
server, credentials, scheduled reader, or production export was provided.

## Run locally

From the repository root, create a `.env` based on `.env.example` and set
different nonempty values for `DB_PASSWORD`, `APP_DB_PASSWORD`, and
`BACKUP_DB_PASSWORD`. These are local-only secrets and `.env` is Git-ignored.
Then run:

```powershell
docker compose up --build --wait
```

Visit `http://127.0.0.1:8080`. PostgreSQL persists in a named Docker volume;
`docker compose down` preserves it. The app uses a restricted role and the
backup role is read-only. Run `python scripts/test_compose.py` to build an
isolated test stack and validate auth allowlisting, SQL permissions, inventory
updates, and re-runnable initialization.

## Azure target

The Terraform under `infra/` provisions Azure Container Apps, a private Azure
Database for PostgreSQL Flexible Server, a private Azure Blob backup container,
private endpoints/DNS, monitoring, managed identities, and a scheduled weekly
backup job. The app is created internally first; enable public ingress only
after Container Apps Easy Auth is configured for the single-tenant Microsoft
Entra application. The app allowlists exact email addresses from
`allowed_users`; unknown or unauthenticated users are denied. The Container
Apps ingress must remain the only route to the app because it supplies the
trusted `X-MS-CLIENT-PRINCIPAL` header.

**No Azure resources are deployed automatically by a local command.** The
GitHub workflows that can incur Azure cost are manual (`workflow_dispatch`)
and should be run only after the subscription, state backend, environment
reviewers, identities, and access settings are prepared.

**Current test deployment:** A synthetic Azure environment has been deployed
manually in North Europe in resource group `last-harvest-rg`. The Container App
uses private-only ingress (`external=false`); it has no public endpoint because
Entra Easy Auth has not been configured. This environment is not production
and contains only generated inventory data. The database has 108 synthetic
inventory rows; a scheduled backup and checksum-verified isolated restore have
both been run successfully, restoring all 108 rows.

### Prerequisites

- Azure subscription and a deployment identity configured for GitHub OIDC.
- The OIDC principal's approved resource-group permissions, including role
  assignment rights for narrowly scoped ACR, Blob, and identity access.
- A pre-created, private Terraform state account/container with blob data access
  for that OIDC principal. Enable blob versioning, soft delete, TLS 1.2+, and
  shared-key access disabled. For a private state endpoint, use a self-hosted
  GitHub runner in the VNet; GitHub-hosted runners cannot reach private IPs.
- A single-tenant Entra app registration with the redirect URI
  `https://<container-app-fqdn>/.auth/login/aad/callback`, plus its client ID
  and client secret in the protected `hackathon` GitHub environment.
- Approved unique database passwords and an exact JSON array of allowed user
  email addresses. Use an approved secret manager, not source or workflow logs.
- An approved Azure region and IP address space that does not overlap the
  existing Azure VNet.

Create the Terraform state backend separately from the stack it stores, using
an approved operator identity. Example bootstrap commands:

```powershell
az group create --name <state-resource-group> --location <approved-region>
az storage account create --resource-group <state-resource-group> --name <unique-state-account> --location <approved-region> --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false
az storage account blob-service-properties update --resource-group <state-resource-group> --account-name <unique-state-account> --enable-versioning true --enable-delete-retention true --delete-retention-days 30
az storage container create --account-name <unique-state-account> --name tfstate --auth-mode login
```

Grant the GitHub OIDC principal `Storage Blob Data Contributor` on the state
container. The example GitHub-hosted workflows need the state blob endpoint
reachable over HTTPS; do not make the container or blobs public. A self-hosted
runner in the VNet permits the state account to use a private endpoint/firewall.
Protect the Terraform state as sensitive: it contains database administrator
and application-role credentials even though Terraform marks them sensitive.

### GitHub configuration

Create a protected GitHub environment named `hackathon`, add required reviewers,
and configure these **environment secrets**:

| Secret | Purpose |
| --- | --- |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | GitHub OIDC Azure deployment identity |
| `POSTGRES_ADMIN_PASSWORD` | PostgreSQL server administrator / one-time bootstrap |
| `APP_DB_PASSWORD` | Restricted web application database role |
| `BACKUP_DB_PASSWORD` | Read-only export database role |
| `ENTRA_TENANT_ID`, `ENTRA_APP_CLIENT_ID`, `ENTRA_APP_CLIENT_SECRET` | Entra sign-in provider for Container Apps Easy Auth |

Configure these **environment variables**:

| Variable | Purpose |
| --- | --- |
| `AZURE_LOCATION` | Approved Azure region |
| `POSTGRES_ADMIN_USERNAME` | PostgreSQL administrator login |
| `ALLOWED_USERS_JSON` | JSON string, e.g. `["alice@example.com","bob@example.com"]` |
| `TF_STATE_RESOURCE_GROUP`, `TF_STATE_STORAGE_ACCOUNT`, `TF_STATE_CONTAINER`, `TF_STATE_KEY` | Existing remote state backend |
| `AZURE_RESOURCE_GROUP`, `AZURE_ACR_NAME`, `AZURE_CONTAINER_APP_NAME`, `AZURE_DB_INIT_JOB_NAME`, `AZURE_BACKUP_JOB_NAME`, `AZURE_RESTORE_JOB_NAME` | Resource names output by Terraform |

The OIDC deployment principal requires permission to create the resource group
and Azure resources, push images to ACR, and assign the specific scoped roles in
Terraform. Scope resource permissions narrowly and grant role-assignment
permission only at the deployment resource group. Prefer an approved custom
role; do not grant subscription Owner merely for convenience.

### Deployment sequence

1. Configure the GitHub environment and state backend above. Set GitHub
   environment variables for location, admin username, and the allowlist; do
   not put credentials in Terraform files. For local validation, copy the
   example to ignored `infra/terraform.tfvars` and set only non-secret values.
   Confirm the app images are absent.
2. Manually run **Provision Azure infrastructure** from Actions. This creates
   the private foundation and incurs Azure charges; the app/backup jobs and
   public ingress remain disabled.
3. Read Terraform outputs and set the resource-name GitHub variables listed
   above. Confirm the Entra callback URI uses the eventual Container Apps FQDN.
4. Manually run **Deploy inventory application** with database initialization
   enabled and public ingress disabled. It pushes three immutable image digests,
   creates the private app and jobs, then initializes the synthetic schema and
   database roles. It configures Entra Easy Auth before exiting.
5. Verify the Entra sign-in app/allowlist and authenticated app privately. Run
   **Deploy inventory application** again with initialization disabled and
   public ingress enabled. The workflow refuses to expose the app unless
   Easy Auth is already set to redirect anonymous requests to sign-in.
6. Verify the public URL sends anonymous browsers to Entra sign-in, allowed
   users can update stock, non-allowlisted users are denied, and app logs show
   no secrets.

Regular releases use immutable ACR digests. A previous image digest can be
restored by redeploying that digest; never destroy infrastructure to roll back.
Do not use multiple app replicas: PHP sessions are stored on local disk and
revision switches may interrupt sessions. Add and validate shared session
storage before scale-out.

### Weekly Azure Blob backup and restore

Terraform creates a Container Apps Job scheduled at **02:00 UTC every Sunday**
and a private Blob container. The job uses a user-assigned managed identity with
`Storage Blob Data Contributor` scoped to that container; an independent
restore identity receives `Storage Blob Data Reader`. Storage public access and
shared-key authentication are disabled. The job connects privately to PostgreSQL
as the read-only backup role with `verify-full` TLS, runs `pg_dump` custom format,
calculates SHA-256, and writes a unique timestamped blob with checksum metadata.

The deployment-created scheduled job is also manually executable:

```powershell
az containerapp job start --resource-group <resource-group> --name <backup-job>
```

Inspect the execution result/logs in Container Apps before calling an export
successful. To prove recovery, manually run **Deploy inventory application**,
set `run_restore` to `true`, and supply the exact blob name in `restore_blob_name`.
The separate restore identity can read blobs but cannot write or delete them. The
job checks the blob's SHA-256 metadata before restoring via TLS into a newly
created `inventory_restore_<UTC timestamp>` database on the private PostgreSQL
server. The job uses the server administrator credential only within this
manually triggered task to create that new database; it never targets the live
`inventory` database. It reports the restored inventory row count in the
Container Apps job logs. Re-running creates another database. Compare the result
and representative quantities with the expected backup before relying on it.

### Terraform and operations

Terraform requires a version from 1.8 to before 2.0. For local validation without
the remote state backend:

```powershell
terraform -chdir=infra init -backend=false
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
```

For remote operations, use the protected backend config shown in the workflows.
Never run `terraform destroy` or delete storage volumes as a recovery shortcut.
Private PostgreSQL/blob endpoints and DNS must resolve from the Container Apps
VNet. The initial schema/roles job is an explicit one-time operation; it is
idempotent and never replaces existing inventory quantities.

## Security and scope limits

- TLS is required from clients at the HTTPS-only Container Apps ingress and
  verified for PostgreSQL. Secrets are not committed, built into images, or
  echoed in workflow output.
- Entra Easy Auth must deny or redirect anonymous users; application allowlisting
  is defense in depth, not a replacement for ingress authentication.
- The local and deployed Azure stacks are synthetic and are **not evidence**
  that Olivier's real application or database was migrated, that the nightly
  reader works, or that the original server has been secured or shut down.
- The PDF names S3; the user requested the Azure equivalent, so the plan uses
  Azure Blob Storage instead. Disclose this deviation during the jury handoff.
