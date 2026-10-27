# Database collectors: one-command installer

`install.sh` sets up the upstream [OpenTelemetry Collector Contrib](https://github.com/open-telemetry/opentelemetry-collector-releases)
(`otelcol-contrib`) on the database host or on a host that can reach the database. The collector then ships
that database's metrics to OpenObserve. With `--dbm` it also ships the Database Monitoring events (blocking
chains, deadlocks, top queries, table/index health) into the `_o2_dbm_server` logs stream.

The configs it writes are the same ones the OpenObserve UI's database setup cards show. They are embedded in
`install.sh` as heredocs, each with a comment naming its source file in the `openobserve` repo
(`web/src/components/ingestion/setupCard/content/<db>.ts` and `dbmShared.ts`).

Supported: PostgreSQL, MySQL, MariaDB, SQL Server, MongoDB and Redis. The script runs on Linux (systemd) and
macOS (launchd), on amd64 and arm64.

## Quick start

```bash
curl -sSLo o2-db-install.sh https://raw.githubusercontent.com/openobserve/o2-datasource/main/databases/install.sh \
  && sudo bash o2-db-install.sh --db=postgres --host=localhost --port=5432 --db-user=myuser \
     --o2-url=https://cloud.openobserve.ai --org-id=default --access-key=<base64> [--dbm]
```

The script asks for the database password on the terminal, and the password is not echoed. Before you run it,
create the monitoring user (see [Prerequisites](#prerequisites-per-database)).

What it does, in order:

1. **Validate.** Checks the flags and value formats, and checks that the access key is base64.
2. **Preflight.**
   - Opens a TCP connection to `host:port`.
   - Optionally checks the login, if `psql`, `mysql`, `mariadb`, `sqlcmd`, `mongosh` or `redis-cli` is
     installed. A failed login only gives a warning.
   - Probes the OpenObserve endpoint.

   If the TCP check or the endpoint probe fails, the script asks on the terminal whether to continue. With no
   terminal, it warns and continues.
3. **Collector.**
   - Downloads `otelcol-contrib` v0.158.0 (override with `O2_OTELCOL_VERSION`) for your OS/arch.
   - Checks it against the release's published `<asset>.sha256`.
   - Installs it to `/usr/local/bin/otelcol-contrib`. If that version is already there, this step is skipped.
4. **Config.**
   - Renders `/etc/otelcol-o2/<name>/config.yaml`, plus `dbm-config.yaml` with `--dbm`.
   - Writes the credentials to `/etc/otelcol-o2/<name>/env`.
   - Runs `otelcol-contrib validate` before anything live is replaced.
5. **Service.** Installs a systemd unit `otelcol-o2-<name>.service` on Linux, or a launchd daemon
   `ai.openobserve.otelcol-o2.<name>` on macOS, then (re)starts it.
6. **Health check.** The service must stay active with no restarts for about 20s. On failure the script prints
   the last logs. If the collector is up but logged receiver errors (bad password, missing grant), it shows them.
7. **Summary.** Prints the config path, status, restart and uninstall commands.

Re-running with the same name is safe. The script rewrites the config and credentials and restarts the
service. Adding `--dbm` on a re-run turns Database Monitoring on; leaving it off removes `dbm-config.yaml`.

### Containers / hosts without systemd

```bash
sudo O2_DB_PASSWORD='...' bash o2-db-install.sh --db=redis --o2-url=... --org-id=... --access-key=... --no-service
# then, in the foreground (e.g. as the container command):
sudo /etc/otelcol-o2/redis-localhost-6379/run.sh
```

`--no-service` writes the config, the credentials and `run.sh`, which loads the env file and `exec`s the
collector. It then prints that foreground command instead of installing a service.

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--db=` | required | `postgres`, `mysql`, `mariadb`, `sqlserver`, `mongodb`, `redis` |
| `--host=` | `localhost` | Hostname or IPv4 address |
| `--port=` | 5432 / 3306 / 3306 / 1433 / 27017 / 6379 | Per database |
| `--db-user=` | `myuser` (postgres), `otel` (mysql, mariadb, sqlserver, mongodb) | Ignored for redis (password-only AUTH) |
| `--database=` | `postgres` (postgres), `mysql` (mysql, mariadb), `master` (sqlserver DBM) | Database the receivers connect to |
| `--o2-url=` | required | `http://` or `https://`, without a trailing path |
| `--org-id=` | required | OpenObserve organization |
| `--access-key=` | required | `echo -n 'email:passcode' \| base64` |
| `--dbm` | off | Also install the Database Monitoring config (postgres, mysql, mariadb, sqlserver) |
| `--log-path=` | `/var/log/postgresql/postgresql*.log` (postgres), `/var/log/mysql/error.log` (mysql, mariadb) | Server log the DBM deadlock recipe tails |
| `--name=` | `<db>-<host>-<port>` | Instance name, lowercased; anything outside `[a-z0-9-]` becomes `-` |
| `--password-file=` | | Password is read from the first line of this file |
| `--tls` | off | mongodb only: connect with verified TLS (the card's default is a plaintext connection) |
| `--no-service` | off | Do not install a service; print the foreground command |
| `--skip-checksum` | off | Install even if the release checksum cannot be fetched (not recommended) |
| `--dry-run` | off | Render and validate (with an installed `otelcol-contrib`, if present); install nothing |
| `--help` | | |

**Password source**, first match wins:

1. The `O2_DB_PASSWORD` environment variable. `sudo` drops your environment, so use
   `sudo O2_DB_PASSWORD=... bash o2-db-install.sh ...`.
2. `--password-file=PATH`.
3. A hidden prompt on `/dev/tty`. This also works under `curl ... | bash`. For redis you can leave it empty to
   connect without AUTH.

The password is never accepted as a flag.

To uninstall:

```bash
curl -sSLo o2-db-uninstall.sh https://raw.githubusercontent.com/openobserve/o2-datasource/main/databases/uninstall.sh
sudo bash o2-db-uninstall.sh --name=postgres-localhost-5432   # or --all; add --remove-binary to drop otelcol-contrib too
```

## Prerequisites per database

These are the prepare steps from the setup cards. Use the same user name you pass as `--db-user`, and the
password you will give the installer.

### PostgreSQL

```sql
CREATE ROLE myuser WITH LOGIN PASSWORD 'mypassword';
```

For `--dbm`, also run the following as a superuser:

```sql
GRANT pg_monitor TO myuser;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

`pg_monitor` lets the collector read other sessions' query text. It does not include SELECT on your tables, so
on a locked-down instance the EXPLAIN-based estimated plans can come back empty.

Then add these to `postgresql.conf` and **restart** Postgres. `log_line_prefix`, `logging_collector` and
`shared_preload_libraries` cannot be reloaded.

```ini
# Must match the collector's log parser — %q keeps background workers parseable.
log_line_prefix = '%m [%p] %q%u@%d app=%a vxid=%v txid=%x line=%l '
logging_collector = on
log_destination = 'stderr'
deadlock_timeout = 500ms
log_lock_waits = on
log_min_duration_statement = 100ms
shared_preload_libraries = 'pg_stat_statements'   # append if the line already lists libraries
```

With `logging_collector = on`, Postgres writes into its `log_directory`. By default that is `log/` inside the
data directory, not `/var/log/postgresql`. Either set `log_directory = '/var/log/postgresql'` and
`log_filename = 'postgresql-%Y-%m-%d.log'`, or point `--log-path` at the real files, for example
`--log-path=/var/lib/postgresql/16/main/log/postgresql-*.log`. If `log_line_prefix` does not match, the
collector stays healthy but ingests no deadlocks.

### MySQL

```sql
CREATE USER 'otel'@'localhost' IDENTIFIED BY 'yourpassword';
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'otel'@'localhost';
FLUSH PRIVILEGES;
```

The collector connects over TCP. If it runs on another host, create the user for that host instead of
`localhost`. For `--dbm`, also run:

```sql
SET PERSIST innodb_print_all_deadlocks = ON;
```

`--log-path` must point at the MySQL error log.

### MariaDB

You need the same user and grants as for MySQL. Use `--db=mariadb`: the DBM recipes are MariaDB-specific and
tag rows as `mariadb`. For `--dbm`, also run:

```sql
SET GLOBAL innodb_print_all_deadlocks = ON;
-- MariaDB has no SET PERSIST: add this to my.cnf ([mysqld] section) so the
-- setting survives a restart, otherwise deadlock history stops silently.
--   innodb_print_all_deadlocks = ON
```

`--db=mysql` against MariaDB also works for metrics. Its MySQL 8 DBM recipes fail against MariaDB, because
MariaDB has no `performance_schema.data_lock_waits`.

### SQL Server

Run this as `sa`. Change the password, then give that same password to the installer.

```sql
USE master;
CREATE LOGIN otel WITH PASSWORD = 'YourStrong@Passw0rd';
-- SQL Server 2022+ has VIEW SERVER PERFORMANCE STATE; 2016-2019 use VIEW SERVER STATE.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
  EXEC('GRANT VIEW SERVER PERFORMANCE STATE TO otel');
ELSE
  EXEC('GRANT VIEW SERVER STATE TO otel');
GRANT VIEW ANY DATABASE TO otel;
```

For `--dbm`, also run:

```sql
GRANT VIEW SERVER STATE TO otel;
-- SQL Server 2022+ also needs VIEW SERVER PERFORMANCE STATE to read the deadlock history.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
  EXEC('GRANT VIEW SERVER PERFORMANCE STATE TO otel');
```

### MongoDB

```javascript
db.getSiblingDB("admin").createUser({ user: "otel", pwd: "password123", roles: [{ role: "clusterMonitor", db: "admin" }] })
```

Use your own password, and give that same password to the installer. Pass `--tls` if the server requires TLS.

### Redis

You don't need a user. If `requirepass` (or an ACL default user password) is set, give that password to the
installer; otherwise leave it empty.

## Security notes

- **No secrets in the config.** The OpenObserve access key and the database password are read from
  `/etc/otelcol-o2/<name>/env` (mode 600, root). `config.yaml` and `dbm-config.yaml` (mode 640) only hold
  `${env:...}` references. The cards' demo passwords (`password123`, `YourStrong@Passw0rd`) are replaced with
  `${env:MONGODB_PASSWORD}` and `${env:MSSQL_PASSWORD}`.
- **No secrets on the command line.** The login check passes the password through each client's own
  environment variable (`PGPASSWORD`, `MYSQL_PWD`, `SQLCMDPASSWORD`, `REDISCLI_AUTH`, and for mongosh a URI built
  inside the shell). Install output shows the access key only in redacted form, and never shows the password.
- **Verified binary.** The collector archive's sha256 is checked against the release's published checksum.
  If the checksum cannot be fetched, the install stops unless you pass `--skip-checksum`.
- **The service runs as root**, so the `--dbm` deadlock recipe can tail the database's server log. It is
  confined with `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only` and `PrivateTmp`.
- **DSN-sensitive characters (`--dbm` only).**
  - Postgres: a password with spaces, quotes or backslashes breaks the libpq `key=value` DSN.
  - SQL Server: a `;` in the password breaks the DSN.

  The installer warns about these; metrics are unaffected.

## Managed databases (RDS, Aurora, Cloud SQL, Azure)

Metrics, and every Database Monitoring signal except deadlocks, work against managed databases. Run the
installer on any VM that can reach the endpoint and pass `--host=<endpoint>`.

**PostgreSQL deadlock capture needs a local log file.** The `filelog/pg_deadlocks` recipe tails the server log
on disk, and RDS, Aurora and Cloud SQL give the collector no filesystem to read it from. Setting the logging
parameters in a parameter group does not change that. The same applies to the MySQL and MariaDB error-log
recipes. SQL Server reads deadlocks from the `system_health` Extended Events session over SQL, so it is not
affected.
