# Azure PostgreSQL Flexible Server → OpenObserve Database Monitoring

Stream Azure Database for PostgreSQL **Flexible Server** logs — executed query
plans, statement durations, lock waits and deadlocks — into OpenObserve's
Database Monitoring pages.

```
PostgreSQL Flexible Server
   │  (Diagnostic Settings, category PostgreSQLLogs)
   ▼
Azure Event Hub
   │  (eventHubTrigger, cardinality=many)
   ▼
Azure Function  ── normalizes the diagnostic envelope into the
   │                attribute names OpenObserve's DBM canonicalizer reads
   ▼
OpenObserve  POST /api/<org>/_o2_dbm_server/_json
```

## Why this exists

The on-host OpenObserve DBM collector captures executed plans with the
OpenTelemetry **filelog** receiver tailing `postgresql.log` for `auto_explain`
output. Flexible Server is fully managed — there is no host filesystem, so
filelog has nothing to tail no matter where the collector runs.

Azure's supported route off the box is Diagnostic Settings → Event Hub. This
datasource is the Azure-side stand-in for that filelog receiver: the Function
reproduces the shipped `filelog/pg` operator chain — same classification order,
same regexes, and **the same attribute names**.

Those names are the contract. OpenObserve's ingest-side canonicalizer reads
collector-produced field names only (`o2_pg_event`, `ae_plan_json`,
`ae_duration_ms`, `stmt_*`, `dl_*`, …). Rename one and the record still
ingests, but it is never canonicalized into an `o2_dbm_*` row — so the
Database Monitoring pages stay empty while every component reports healthy.

---

## Quick start

```bash
chmod +x deploy.sh
./deploy.sh
```

The script:

1. Checks prerequisites (Azure CLI, `zip`, an active login)
2. Lists your Flexible Servers and lets you pick which to stream
3. Collects OpenObserve connection details
4. Deploys the ARM template (Event Hub, Function App, Storage, Diagnostic Settings)
5. Uploads the forwarder code
6. Optionally sets the Postgres server parameters DBM needs

### Deploying the template directly

```bash
az group create --name rg-openobserve-postgres-logs --location eastus

az deployment group create \
  --resource-group rg-openobserve-postgres-logs \
  --name o2-pgflex-deploy \
  --template-file postgres-logs-to-openobserve.json \
  --parameters \
    openObserveBaseUrl="https://api.openobserve.ai" \
    openObserveOrganization="default" \
    openObserveUsername="you@example.com" \
    openObservePassword="<password>" \
    postgresServerResourceIds='["/subscriptions/.../flexibleServers/mypgsrv"]'
```

Then push the function code:

```bash
(cd function && zip -r /tmp/fn.zip .)
az functionapp deployment source config-zip \
  --resource-group rg-openobserve-postgres-logs \
  --name <functionAppName-from-outputs> --src /tmp/fn.zip
```

Servers in a **different subscription** than the pipeline cannot be attached by
the template — ARM extension resources do not cross subscriptions. Attach them
with `./configure-diagnostic-settings.sh` while logged in to that subscription.

---

## PostgreSQL server parameters

**The pipeline delivers nothing interesting until these are set.** `auto_explain`
is what produces executed plans; it must log JSON for OpenObserve to read the
plan document.

| Parameter | Value | Notes |
|---|---|---|
| `shared_preload_libraries` | `+= auto_explain` | **requires a server restart** |
| `auto_explain.log_format` | `json` | mandatory — `text` yields no `ae_plan_json` |
| `auto_explain.log_analyze` | `on` | supplies real durations and `Actual Rows` |
| `auto_explain.log_timing` | `off` | per-node timing is expensive; leave off |
| `auto_explain.log_min_duration` | `1000` (ms) | lower captures more plans, and more volume |
| `log_min_duration_statement` | `1000` (ms) | per-execution statement durations |
| `log_lock_waits` | `on` | lock waits, and deadlock DETAIL blocks |
| `compute_query_id` | `on` | stable join key across vantages |

```bash
az postgres flexible-server parameter set -g <rg> -s <server> \
  --name shared_preload_libraries --value "pg_stat_statements,auto_explain"
az postgres flexible-server restart -g <rg> -n <server>

az postgres flexible-server parameter set -g <rg> -s <server> \
  --name auto_explain.log_format --value json
# ... and the rest of the table
```

`shared_preload_libraries` is **additive** — read the current value first, or
you will drop `pg_stat_statements` and whatever else the server already loads.
`deploy.sh` does this for you.

Statement logging has real overhead on a busy server. Start at 1000 ms, watch
the ingest volume, then lower it.

---

## What the Function does

Each Event Hub message is an Azure diagnostic envelope:

```json
{"records":[{
  "resourceId":"/SUBSCRIPTIONS/.../FLEXIBLESERVERS/MYPGSRV",
  "time":"2026-08-13T02:49:33.262Z",
  "category":"PostgreSQLLogs",
  "operationName":"LogEvent",
  "properties":{
    "prefix":"",
    "message":"2026-08-13 02:49:33.262 UTC [497] [user=dbm,db=dbmlab,app=t1probe] LOG:  duration: 0.009 ms  plan:\n{\"Query Text\": ...}",
    "errorLevel":"LOG",
    "detail":"",
    "sqlerrcode":"00000"
  }
}]}
```

On Flexible Server `properties.prefix` is empty and `properties.message` carries
the whole log line, prefix and severity included. The Function unwraps the
envelope, parses the line, classifies it, and emits one flat record per event.

### Classification and emitted fields

| `o2_pg_event` | Matched on | Fields emitted | Canonicalized by OpenObserve into |
|---|---|---|---|
| `explain` | `duration: N ms  plan:` | `ae_duration_ms`, `ae_plan_json`, `o2_explain_raw` | `o2_dbm_kind=explain`, `o2_dbm_plan`, `o2_dbm_plan_hash`, `o2_dbm_plan_duration_ms` |
| `statement_duration` | `duration: N ms  statement/execute/bind/parse:` | `stmt_duration_ms`, `stmt_kind`, `stmt_text` | `o2_dbm_kind=statement` |
| `deadlock` | `deadlock detected`, and the DETAIL wait cycle | `dl_*`, `deadlock_victim_pid`, `o2_deadlock_raw` | `o2_dbm_kind=deadlock` *(Enterprise)* |
| `lock_wait` | `still waiting for` | `lw_pid`, `lw_lock_mode`, `lw_lock_target`, `lw_wait_ms` | — |
| `lock_acquired` | `acquired … Lock on` | same `lw_*` set | — |
| `temp_file` | `temporary file:` | `tmp_path`, `tmp_size_bytes` | — |
| `other` | everything else | dropped, unless `forwardNonDbmLogs` | — |

Every record also carries `pg_pid`, `pg_user`, `pg_db`, `pg_app`, `pg_severity`,
`body`, `db_system_name=postgresql`, `o2_vantage=server` and `server_address`,
plus Azure provenance under `az_*`.

`server_address` is the **instance dimension** the Database Monitoring instance
filter matches on. It is derived per record as
`<server>.postgres.database.azure.com`, so one Function App can serve several
servers. Override it with `postgresServerAddressOverride`, or change the suffix
with `postgresDnsSuffix` for sovereign clouds.

### Ordering matters in one place

An `auto_explain` entry begins `duration: N.NNN ms  plan:`, so it also matches
the bare `^duration:` test. The explain check runs first. Reverse them and every
plan is filed as a statement duration, and the executed-plan pages stay empty.

### Why non-DBM lines are dropped by default

The Function tails the whole server log, exactly as filelog does. On a real
deployment OpenObserve measured 787 tagged events against 4.8 **million**
untagged rows in the same hour on this stream, which took the Deadlocks page
from sub-second to 8–18 s. `forwardNonDbmLogs: true` routes those lines to a
separate stream instead — never into `_o2_dbm_server`.

---

## Verifying

```bash
az webapp log tail --name <functionAppName> --resource-group <rg>
```

In OpenObserve, run against the `_o2_dbm_server` stream:

```sql
SELECT o2_dbm_kind, count(*) FROM "_o2_dbm_server" GROUP BY o2_dbm_kind
```

Rows with a non-null `o2_dbm_kind` were canonicalized; the DBM pages read those.

| Symptom | Cause |
|---|---|
| Records arrive, `o2_dbm_kind` is always null | Database Monitoring is off in OpenObserve (`ZO_DB_MONITORING_ENABLED`), or the records went to a stream other than `_o2_dbm_server` |
| `o2_pg_event=explain` rows have no `ae_plan_json` | `auto_explain.log_format` is not `json`, or Azure truncated the plan (see below). The Function logs a warning with a count |
| No `explain` rows at all | `auto_explain` not in `shared_preload_libraries`, or the server was not restarted after adding it, or `auto_explain.log_min_duration` is `-1` |
| `"N log line(s) did not match any log_line_prefix pattern"` | `log_line_prefix` was changed to a shape the Function does not know — see `PREFIX_PATTERNS` in the function source |
| Nothing at all reaches the Event Hub | Diagnostic Settings missing, or the `PostgreSQLLogs` category not enabled |

---

## Known limitations

- **Azure Monitor drops log events larger than 65 KB.** A plan larger than that is truncated by
  Azure Monitor before it reaches the Event Hub, so the JSON document does not
  close and no `ae_plan_json` is set. Deeply nested plans (queries over stacked
  views) are the ones that hit this. It is an Azure-side limit; nothing in this
  pipeline can recover the missing bytes.
- **DETAIL is folded into the parent record.** Flexible Server does not emit
  `DETAIL`/`HINT`/`CONTEXT` as their own log events — it puts DETAIL in
  `properties.detail`. A deadlock's wait cycle and every participant's SQL live
  there, so the Function re-emits it as the separate DETAIL entry an on-host
  tailer would have produced, correlated to its parent by pid. `HINT`,
  `CONTEXT` and `STATEMENT` are not available on Azure at all.
- **`log_line_prefix` is a server parameter.** The Function knows the Azure
  default (`%m [%p] [user=%u,db=%d,app=%a] `), the prefix the OpenObserve DBM
  docs recommend, and a generic fallback. A prefix unlike all three parses only
  partially, which shows up as missing `pg_db` / `pg_user`.
- **Deadlock and blocking pages are Enterprise-only** in OpenObserve. The
  records ingest and canonicalize on any build; the pages that read them need a
  licence.
- **One Function instance per Event Hub partition.** A busy server needs more
  than the default 4 partitions; `eventHubPartitionCount` is a deploy-time
  parameter and cannot be lowered afterwards.

---

## Alternative: normalize in an OpenObserve pipeline instead

Everything the Function does can be done with a VRL pipeline in OpenObserve,
with the Event Hub writing raw records into a landing stream. That trades an
Azure resource for an OpenObserve one; the field contract is identical.

The core of it, for the explain path:

```coffee
# Unwrap the Azure envelope and recover the Postgres log line
line = string!(.properties.message)

parsed, err = parse_regex(line,
  r'^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ \w+) \[(?P<pg_pid>\d+)\] (?:\[user=(?P<pg_user>.*?),db=(?P<pg_db>.*?),app=(?P<pg_app>.*?)\] )?(?P<pg_severity>[A-Z]+):\s+(?P<pg_message>[\s\S]*)$')
if err == null { . = merge(., parsed) }

msg = string(.pg_message) ?? ""
if match(msg, r'^duration: [\d.]+ ms\s+plan:') {
  .o2_pg_event = "explain"
  head, _ = parse_regex(msg, r'^duration: (?P<d>[\d.]+) ms')
  if head != null { .ae_duration_ms = to_float(head.d) ?? null }
  # ONE STRING attribute — never parse it into an object, the canonicalizer
  # requires a scalar and a nested value can reject the whole batch
  plan, _ = parse_regex(msg, r'plan:\s*(?P<p>\{[\s\S]*\})\s*$')
  if plan != null { .ae_plan_json = plan.p }
} else if match(msg, r'^duration:') {
  .o2_pg_event = "statement_duration"
}

.db_system_name = "postgresql"
.o2_vantage = "server"
.server_address = replace(string!(.resourceId), r'^.*/', "") + ".postgres.database.azure.com"
```

Route the pipeline's output to `_o2_dbm_server` and drop records where
`o2_pg_event` is null. The Function is the packaged path because it also handles
DETAIL re-emission, multi-record envelopes, batching and the `log_line_prefix`
fallbacks; the VRL above covers the plans case only.

---

## Files

| File | Purpose |
|---|---|
| `postgres-logs-to-openobserve.json` | ARM template — Event Hub, Function App, Storage, Diagnostic Settings |
| `deploy.sh` | Interactive deploy: template, function code, server parameters |
| `configure-diagnostic-settings.sh` | Attach servers to an existing deployment (incl. other subscriptions) |
| `cleanup.sh` | Remove Diagnostic Settings, then the deployed resources |
| `function/PostgresLogForwarder/__init__.py` | The forwarder — the `filelog/pg` operator chain, in Python |

## Cleanup

```bash
chmod +x cleanup.sh
./cleanup.sh
```

Diagnostic Settings are removed before the Event Hub, so no server is left
writing into a destination that no longer exists. Postgres server parameters are
**not** reverted — reset them yourself if you want the logging overhead back off.
