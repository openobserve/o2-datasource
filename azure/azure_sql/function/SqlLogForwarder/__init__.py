"""Azure SQL Managed Instance / Azure SQL Database diagnostics -> OpenObserve.

Unlike PostgreSQL Flexible Server, Azure SQL does not export a server log. Every
diagnostic category (Query Store runtime and wait statistics, SQLInsights,
Errors, ResourceUsageStats, and on Azure SQL Database also Deadlocks, Blocks,
Timeouts and DatabaseWaitStatistics) arrives as an already-structured record:

    {"records": [{
        "time": "2026-10-06T10:15:00.0000000Z",
        "resourceId": "/SUBSCRIPTIONS/.../MANAGEDINSTANCES/MYMI/DATABASES/APPDB",
        "category": "QueryStoreRuntimeStatistics",
        "operationName": "QueryStoreRuntimeStatisticsEvent",
        "LogicalServerName": "mymi",
        "properties": {"DatabaseName": "appdb", "query_hash": "0x...", ...}
    }]}

So there is nothing to parse. This function unwraps the envelope, flattens
`properties` into one record per event, adds the server/database identity, and
posts the result to an ordinary OpenObserve stream.

It deliberately does NOT write to `_o2_dbm_server`: that is an internal rollup
stream whose canonicalizer reads PostgreSQL collector field names, and SQL
Server records written there would ingest but never surface on any page.
"""

import json
import logging
import os
import re
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

DEFAULT_STREAM = "azure_sql_logs"
DEFAULT_SQL_DNS_SUFFIX = "database.windows.net"

# Keep each POST comfortably below OpenObserve's default request-size ceiling.
MAX_PAYLOAD_BYTES = 4 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 30
HTTP_MAX_ATTEMPTS = 3
RETRYABLE_STATUS = frozenset((408, 429, 500, 502, 503, 504))

# Field names this function sets itself. A `properties` key that collides with
# one of them -- compared case-insensitively, because OpenObserve lowercases
# field names on ingest -- is kept under `sql_<key>` instead of overwriting it.
_RESERVED = frozenset(
    (
        "_timestamp",
        "body",
        "db_system_name",
        "server_address",
        "az_resource_id",
        "az_subscription_id",
        "az_resource_group",
        "az_category",
        "az_operation_name",
        "az_logical_server_name",
        "az_server_type",
        "az_server_name",
        "az_database_name",
        "az_ingest_source",
    )
)

# /SUBSCRIPTIONS/<sub>/RESOURCEGROUPS/<rg>/PROVIDERS/MICROSOFT.SQL/
#   SERVERS/<srv>[/DATABASES/<db>]           -> Azure SQL Database
#   MANAGEDINSTANCES/<mi>[/DATABASES/<db>]   -> Azure SQL Managed Instance
_RE_SQL_RESOURCE = re.compile(
    r"/providers/microsoft\.sql/(?P<kind>servers|managedinstances)/(?P<server>[^/]+)"
    r"(?:/databases/(?P<database>[^/]+))?",
    re.IGNORECASE,
)


def _parse_azure_time(value):
    """Parse the Azure envelope's `time` (RFC 3339, always UTC) to epoch micros."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    # Python's parser accepts at most 6 fractional digits; Azure emits 7
    # (.NET "round-trip" format).
    text = re.sub(r"\.(\d{6})\d+", r".\1", text)
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1_000_000)


def _resource_identity(resource_id):
    """Return `(server_type, server_name, database_name)` from a resource ID."""
    match = _RE_SQL_RESOURCE.search(resource_id or "")
    if not match:
        return None, None, None
    server_type = (
        "sql_managed_instance"
        if match.group("kind").lower() == "managedinstances"
        else "sql_database"
    )
    database = match.group("database")
    return server_type, match.group("server").lower(), database.lower() if database else None


def _scalar(value):
    """Keep scalars as-is; serialize anything nested to a JSON string.

    OpenObserve flattens nested objects on its own, but a field that is an
    object on one record and a string on another is a schema conflict that can
    reject a batch. A string is always a string.
    """
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return json.dumps(value, separators=(",", ":"), default=str)


def _build_record(envelope, instance_override, dns_suffix):
    """Turn one Azure diagnostic record into one flat OpenObserve record."""
    properties = envelope.get("properties")
    if isinstance(properties, str):
        # Some categories have shipped `properties` as an encoded JSON string.
        try:
            properties = json.loads(properties)
        except ValueError:
            properties = {"properties": properties}
    if not isinstance(properties, dict):
        properties = {}

    resource_id = envelope.get("resourceId") or ""
    server_type, server_name, database_name = _resource_identity(resource_id)
    logical_server = envelope.get("LogicalServerName")
    if not server_name and isinstance(logical_server, str) and logical_server:
        server_name = logical_server.lower()
    if not database_name:
        db_prop = properties.get("DatabaseName")
        if isinstance(db_prop, str) and db_prop:
            database_name = db_prop.lower()

    category = envelope.get("category") or ""
    record = {
        # OpenTelemetry's `db.system.name` value for SQL Server.
        "db_system_name": "microsoft.sql_server",
        "az_ingest_source": "azure-eventhub",
    }

    for src, dst in (
        ("resourceId", "az_resource_id"),
        ("SubscriptionId", "az_subscription_id"),
        ("ResourceGroup", "az_resource_group"),
        ("category", "az_category"),
        ("operationName", "az_operation_name"),
        ("LogicalServerName", "az_logical_server_name"),
    ):
        value = envelope.get(src)
        if isinstance(value, (str, int, float)) and value != "":
            record[dst] = value

    if server_type:
        record["az_server_type"] = server_type
    if server_name:
        record["az_server_name"] = server_name
    if database_name:
        record["az_database_name"] = database_name

    # A Managed Instance's FQDN includes a per-instance DNS zone
    # (<mi>.<zone>.database.windows.net) that appears nowhere in the record, so
    # only Azure SQL Database gets a derived hostname; an instance reports its
    # name unless SQL_SERVER_ADDRESS pins it.
    if instance_override:
        record["server_address"] = instance_override
    elif server_name and server_type == "sql_database" and dns_suffix:
        record["server_address"] = "{}.{}".format(server_name, dns_suffix)
    elif server_name:
        record["server_address"] = server_name

    for key, value in properties.items():
        if not isinstance(key, str) or not key:
            continue
        value = _scalar(value)
        if value is None or value == "":
            continue
        record["sql_" + key if key.lower() in _RESERVED else key] = value

    timestamp = _parse_azure_time(envelope.get("time"))
    if timestamp is None:
        timestamp = int(time.time() * 1_000_000)
    record["_timestamp"] = timestamp

    # A short, searchable summary. The data itself is in the fields above;
    # repeating the whole record here would double every row's size.
    summary = [category or "unknown"]
    if server_name:
        summary.append(server_name if not database_name else server_name + "/" + database_name)
    for key in ("error_number", "Message", "message", "query_hash", "wait_category"):
        value = properties.get(key)
        if isinstance(value, (str, int, float)) and value != "":
            summary.append("{}={}".format(key, value))
            break
    record["body"] = " ".join(str(part) for part in summary)

    return record


def _records_from_message(body):
    """Yield Azure diagnostic records from one Event Hub message body."""
    body = body.strip()
    if not body:
        return []
    try:
        data = json.loads(body)
    except ValueError:
        # Some producers concatenate JSON objects one per line. Recursing on a
        # SINGLE line would re-enter this branch with the same text forever, so
        # a body that is one unparseable line stops here.
        lines = [line.strip() for line in body.splitlines()]
        lines = [line for line in lines if line]
        if len(lines) < 2:
            logging.warning("Skipping unparseable Event Hub message (%d bytes)", len(body))
            return []
        out = []
        for line in lines:
            out.extend(_records_from_message(line))
        return out

    if isinstance(data, dict) and isinstance(data.get("records"), list):
        return data["records"]
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return [data]
    return []


def _event_body(event):
    if hasattr(event, "get_body"):
        raw = event.get_body()
    else:
        raw = event
    if isinstance(raw, (bytes, bytearray)):
        return raw.decode("utf-8", errors="replace")
    if isinstance(raw, str):
        return raw
    return str(raw)


def _chunks(records):
    """Split records into POST-sized batches.

    A single record larger than the cap cannot be split, so it is sent alone
    and the batch does exceed the cap -- logged, because the resulting 413 is
    not retryable and would otherwise look like an unexplained failure.
    """
    batch, size = [], 2  # the enclosing "[]"
    for record in records:
        encoded = len(json.dumps(record).encode("utf-8")) + 1  # + separator
        if encoded > MAX_PAYLOAD_BYTES:
            logging.warning(
                "Single record of %d bytes exceeds the %d byte POST cap; sending alone",
                encoded, MAX_PAYLOAD_BYTES,
            )
        if batch and size + encoded > MAX_PAYLOAD_BYTES:
            yield batch
            batch, size = [], 2
        batch.append(record)
        size += encoded
    if batch:
        yield batch


class _Unreachable(Exception):
    """OpenObserve could not be reached at all; further chunks would also fail."""


def _log_ingest_result(records, payload_bytes, body):
    """Report what OpenObserve actually accepted.

    `_json` answers HTTP 200 even when it rejects records -- e.g. "Too old
    data" for a backlog older than ZO_INGEST_ALLOWED_UPTO -- and says so only in
    the body's per-stream `failed` count. Retrying cannot fix those, so they
    are logged as errors rather than raised.
    """
    failed, errors = 0, []
    try:
        parsed = json.loads(body or b"{}")
        for status in parsed.get("status") or []:
            failed += int(status.get("failed") or 0)
            if status.get("error"):
                errors.append(str(status["error"]))
    except (ValueError, TypeError, AttributeError):
        pass
    if failed:
        logging.error(
            "OpenObserve rejected %d of %d records: %s",
            failed, len(records), "; ".join(errors)[:1000] or "<no reason given>",
        )
    else:
        logging.info("Sent %d records to OpenObserve (%d bytes)", len(records), payload_bytes)


def _post(url, access_key, records):
    """POST one batch to OpenObserve's `_json` ingest endpoint."""
    payload = json.dumps(records).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic " + access_key,
        },
    )
    last_error = None
    for attempt in range(1, HTTP_MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                body = response.read()
            _log_ingest_result(records, len(payload), body)
            return
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code not in RETRYABLE_STATUS:
                # The response body is where OpenObserve says WHY -- a schema
                # conflict on the stream, a bad org, a rejected batch.
                try:
                    detail = exc.read().decode("utf-8", errors="replace")[:1000]
                except Exception:  # noqa: BLE001
                    detail = "<no body>"
                logging.error(
                    "OpenObserve rejected %d records: HTTP %s %s -- %s",
                    len(records), exc.code, exc.reason, detail,
                )
                raise
        except Exception as exc:  # noqa: BLE001 - network errors are all retryable
            last_error = exc
        if attempt < HTTP_MAX_ATTEMPTS:
            time.sleep(2 ** (attempt - 1))
    logging.error("Giving up after %d attempts: %s", HTTP_MAX_ATTEMPTS, last_error)
    if isinstance(last_error, urllib.error.HTTPError):
        raise last_error
    raise _Unreachable(str(last_error)) from last_error


def main(events) -> None:
    base_url = (os.environ.get("OPENOBSERVE_BASE_URL", "") or "").rstrip("/")
    organization = os.environ.get("OPENOBSERVE_ORGANIZATION", "default")
    access_key = os.environ.get("OPENOBSERVE_ACCESS_KEY", "")
    stream = os.environ.get("STREAM_NAME", "") or DEFAULT_STREAM
    instance_override = (os.environ.get("SQL_SERVER_ADDRESS", "") or "").strip()
    dns_suffix = (
        os.environ.get("SQL_DNS_SUFFIX", "") or DEFAULT_SQL_DNS_SUFFIX
    ).strip().lstrip(".")

    if not base_url or not access_key:
        logging.error(
            "Missing OPENOBSERVE_BASE_URL or OPENOBSERVE_ACCESS_KEY; nothing forwarded"
        )
        return

    url = "{}/api/{}/{}/_json".format(base_url, organization, stream)

    records = []
    categories = {}
    for event in events if isinstance(events, list) else [events]:
        try:
            azure_records = _records_from_message(_event_body(event))
        except Exception as exc:  # noqa: BLE001
            logging.error("Error reading Event Hub message: %s", exc)
            continue

        for envelope in azure_records:
            if not isinstance(envelope, dict):
                continue
            record = _build_record(envelope, instance_override, dns_suffix)
            records.append(record)
            category = record.get("az_category", "unknown")
            categories[category] = categories.get(category, 0) + 1

    # A chunk OpenObserve rejects does not stop the others. An unreachable
    # OpenObserve does: every further chunk would burn its own ~90 s of retries
    # and run the invocation into the host timeout. Either failure is then
    # re-raised -- the Event Hubs trigger checkpoints past a failed invocation
    # unless a retry policy is set, which is why function.json carries one. It
    # replays the whole invocation, so chunks that already succeeded can be
    # delivered twice.
    failure = None
    for batch in _chunks(records):
        try:
            _post(url, access_key, batch)
        except _Unreachable as exc:
            failure = exc
            break
        except Exception as exc:  # noqa: BLE001
            failure = exc
    if failure is not None:
        raise failure

    logging.info(
        "Forwarded %d record(s) to %s: %s",
        len(records), stream,
        ", ".join("{}={}".format(k, v) for k, v in sorted(categories.items())) or "none",
    )
