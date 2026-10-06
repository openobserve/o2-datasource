# Azure SQL (Managed Instance / Database) → OpenObserve

Stream Azure SQL Managed Instance and Azure SQL Database diagnostics (Query
Store runtime and wait statistics, SQLInsights, errors, instance resource usage)
into an OpenObserve stream.

```
SQL Managed Instance / Azure SQL Database
   │  (Diagnostic Settings, per instance and per database)
   ▼
Azure Event Hub
   │  (eventHubTrigger, cardinality=many)
   ▼
Azure Function  ── flattens each diagnostic record into one row
   │
   ▼
OpenObserve  POST /api/<org>/azure_sql_logs/_json
```

## How this differs from the PostgreSQL Flexible Server datasource

The Event Hub, Function App and Diagnostic Settings plumbing is the same as
`azure_postgresql_flexible_server`. What flows through it is not:

- **There is no server log to parse.** Postgres exports its text log, which
  the Postgres function parses for `auto_explain` plans, statement durations
  and deadlocks. Azure SQL exports already-structured records per category, so
  this function only unwraps and flattens them.
- **The data goes to an ordinary stream, not `_o2_dbm_server`.** That stream's
  canonicalizer reads PostgreSQL collector fields. These records are
  queryable in Logs and usable in dashboards and alerts; they do not populate
  the Database Monitoring pages.
- **What Azure does not export cannot be forwarded.** Query Store records
  carry `query_hash` / `query_plan_hash` and per-interval aggregates, with
  **no query text and no plan XML**. Managed Instance has **no** `Deadlocks`,
  `Blocks` or `Timeouts` categories. Those need a collector that connects to the
  instance (Query Store views, `system_health` Extended Events).

---

## Quick start

```bash
chmod +x deploy.sh
./deploy.sh
```

The script:

1. Checks prerequisites (Azure CLI, `zip`, an active login)
2. Lists Managed Instances, their databases, and Azure SQL databases, and lets
   you pick which to stream
3. Collects OpenObserve connection details
4. Deploys the ARM template (Event Hub, Function App, Storage, Diagnostic Settings)
5. Uploads the forwarder code

### Deploying from the portal

Search for **Deploy a custom template** → **Build your own template in the
editor** → **Load file** → `sql-logs-to-openobserve.json` → **Save**.

Array parameters must be entered as JSON:

```
instanceResourceIds  ["/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>"]
databaseResourceIds  ["/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi>/databases/<db>"]
```

Both may be left as `[]` and attached afterwards with
`configure-diagnostic-settings.sh`.

### Deploying the template with the CLI

```bash
az group create --name rg-openobserve-sql-logs --location eastus

az deployment group create \
  --resource-group rg-openobserve-sql-logs \
  --name o2-azsql-deploy \
  --template-file sql-logs-to-openobserve.json \
  --parameters \
    o2Endpoint="https://api.openobserve.ai" \
    o2Organization="default" \
    o2Username="you@example.com" \
    o2Password="<password>" \
    instanceResourceIds='["/subscriptions/.../managedInstances/mymi"]' \
    databaseResourceIds='["/subscriptions/.../managedInstances/mymi/databases/appdb"]'
```

The template pulls the function code from `functionPackageUrl` — the package
the repo's S3 workflow publishes from `main`. Until that has run for this
datasource the URL does not exist and the Function App has no code. To push the
local code instead, remove the package setting first (zip deploy refuses to run
while it points at a URL):

```bash
az functionapp config appsettings delete \
  --resource-group rg-openobserve-sql-logs \
  --name <functionAppName-from-outputs> --setting-names WEBSITE_RUN_FROM_PACKAGE
(cd function && zip -r /tmp/fn.zip .)
az functionapp deployment source config-zip \
  --resource-group rg-openobserve-sql-logs \
  --name <functionAppName-from-outputs> --src /tmp/fn.zip
```

### Region

Deploy the pipeline in the **same region** as the instances and databases.
Azure Monitor streams diagnostics only to an Event Hub in the monitored
resource's region; a cross-region attach fails at the Diagnostic Settings step.
For resources in several regions, deploy once per region, each into its own
resource group (resource names are derived from the resource group).

Resources in a **different subscription** than the pipeline cannot be attached
by the template — ARM extension resources do not cross subscriptions. Attach
them with `./configure-diagnostic-settings.sh`, staying logged in to the
**pipeline's** subscription (the script reads the deployment's outputs there)
and passing each resource's full ID; your account needs rights on both.

---

## Diagnostic categories

Categories are attached at two levels, and a category set on the wrong level
fails with `Category '...' is not supported`.

| Resource | Resource ID ends in | Categories |
|---|---|---|
| Managed Instance | `/managedInstances/<mi>` | `ResourceUsageStats` *(default)*, `SQLSecurityAuditEvents`, `DevOpsOperationsAudit` |
| Managed Instance database | `/managedInstances/<mi>/databases/<db>` | `SQLInsights`, `QueryStoreRuntimeStatistics`, `QueryStoreWaitStatistics`, `Errors` *(all default)* |
| Azure SQL Database | `/servers/<srv>/databases/<db>` | the four above *(default)*, plus `DatabaseWaitStatistics`, `Timeouts`, `Blocks`, `Deadlocks`, `AutomaticTuning` |

An Azure SQL Database **server** (`/servers/<srv>`) has no categories of its
own for this — list its databases. Dedicated SQL pools (DataWarehouse edition)
have a different category set and are not supported. The template's two
category lists are `instanceLogCategories` and `databaseLogCategories`;
`configure-diagnostic-settings.sh` takes `--instance-categories` and
`--database-categories`.

Query Store categories carry data only while Query Store is enabled on the
database. It is on by default for both Managed Instance and Azure SQL Database;
check with `SELECT actual_state_desc FROM sys.database_query_store_options`.

---

## What the Function emits

One flat row per diagnostic record:

| Field | Source |
|---|---|
| `_timestamp` | the record's `time` |
| every key of `properties` | Azure's names and values; nested values become JSON strings |
| `az_category`, `az_operation_name`, `az_resource_id`, `az_subscription_id`, `az_resource_group`, `az_logical_server_name` | the envelope |
| `az_server_type` | `sql_managed_instance` or `sql_database` |
| `az_server_name`, `az_database_name` | parsed from the resource ID |
| `server_address` | `<server>.database.windows.net` for Azure SQL Database; the instance name for Managed Instance (its DNS zone is not in the record), unless `sqlServerAddressOverride` is set |
| `db_system_name` | `microsoft.sql_server` |
| `body` | a one-line summary: category, server/database, and a key field |

A `properties` key that collides with one of these names (case-insensitively)
is kept as `sql_<key>`. OpenObserve normalizes field names on ingest, so a
property such as `DatabaseName` is queried as `databasename`.

### Delivery

A batch OpenObserve fails to accept is retried by the Function runtime (five
times, exponential backoff up to 5 minutes, set in `function.json`); the whole
invocation is replayed, so rows that already landed can appear twice. A batch
that still fails after that is dropped and logged — visible only if Application
Insights is on (see *Verifying*). Records OpenObserve rejects inside a
successful response (for example "Too old data" after a long outage) cannot be
fixed by retrying and are logged as errors, not retried.

Units are Azure's: Query Store `duration` and `cpu_time` values are in
**microseconds**.

---

## Verifying

The template does not create Application Insights, so Function logs are not
retained by default. To see them, turn it on under the Function App →
**Application Insights**; each invocation then logs
`Forwarded N record(s) to azure_sql_logs: <category>=<count>, ...`.

In OpenObserve:

```sql
SELECT az_category, az_server_name, count(*) FROM "azure_sql_logs"
GROUP BY az_category, az_server_name
```

| Symptom | Cause |
|---|---|
| Deployment fails with `Category '...' is not supported` | A category on the wrong resource level, or a non-SQL resource ID — see *Diagnostic categories* |
| Deployment fails at a Diagnostic Setting with a region error | The Event Hub is not in the resource's region |
| Nothing reaches the Event Hub | Diagnostic Settings missing; check with `az monitor diagnostic-settings list --resource <id>` |
| Only `ResourceUsageStats` rows | No databases attached — database-level categories are set per database |
| No `QueryStore*` rows | Query Store is off or read-only on the database, or no queries ran in the interval |

---

## Files

| File | Purpose |
|---|---|
| `sql-logs-to-openobserve.json` | ARM template — Event Hub, Function App, Storage, Diagnostic Settings |
| `deploy.sh` | Interactive deploy: template and function code |
| `configure-diagnostic-settings.sh` | Attach instances/databases to an existing deployment (incl. other subscriptions) |
| `cleanup.sh` | Remove Diagnostic Settings, then the deployed resources |
| `function/SqlLogForwarder/__init__.py` | The forwarder |

## Cleanup

```bash
chmod +x cleanup.sh
./cleanup.sh
```

Diagnostic Settings are removed before the Event Hub, so no resource is left
writing into a destination that no longer exists.
