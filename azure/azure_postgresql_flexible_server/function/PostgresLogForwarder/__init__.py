"""Azure Database for PostgreSQL Flexible Server logs -> OpenObserve DB Monitoring.

Azure Flexible Server is fully managed: there is no host filesystem, so the
OpenTelemetry `filelog` receiver that the on-host OpenObserve DBM collector uses
to tail `postgresql.log` has nothing to tail. The supported path on Azure is
Diagnostic Settings -> Event Hub -> this function.

This module is the Azure-side stand-in for the shipped `filelog/pg` receiver.
It reproduces that receiver's operator chain -- the same classification order,
the same regexes, and above all **the same attribute names** -- because
OpenObserve's ingest-side canonicalizer reads collector-produced field names
only (`o2_pg_event`, `ae_plan_json`, `ae_duration_ms`, `stmt_*`, `dl_*`, ...).
Rename any of them and the record still ingests but is never canonicalized into
an `o2_dbm_*` row, so the Database Monitoring pages stay empty while everything
reports healthy.

Records are posted to the `_o2_dbm_server` stream, which is the only stream the
DBM read APIs query.
"""

import json
import logging
import os
import re
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Log-line prefix parsing
#
# `properties.message` on Flexible Server carries the WHOLE log line, prefix and
# severity included (unlike Single Server, where `properties.prefix` is separate
# -- see `_reconstruct_line`). The prefix shape therefore depends on the
# server's `log_line_prefix` parameter, so several are tried in order.
#
# `pg_message` is the only group allowed to span lines: an auto_explain entry is
# one multi-line log event, and Azure delivers it as one record.
# ---------------------------------------------------------------------------
_TS = r"(?P<ts>\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\s+\S+)?)"
_SEVERITY = r"(?P<pg_severity>[A-Z][A-Z0-9]*)"
_BODY = r"(?P<pg_message>[\s\S]*)$"

PREFIX_PATTERNS = (
    # Azure Flexible Server default: `%m [%p] [user=%u,db=%d,app=%a] `.
    # The user/db/app values are `[unknown]` for backends that have not
    # authenticated yet, so the inner groups must tolerate square brackets --
    # hence the lazy `[^\n]*?` rather than a negated character class.
    re.compile(
        _TS + r"\s+\[(?P<pg_pid>\d+)\]\s*"
        r"(?:\[user=(?P<pg_user>[^\n]*?),db=(?P<pg_db>[^\n]*?),app=(?P<pg_app>[^\n]*?)\]\s*)?"
        r"(?:\[(?P<pg_extra>[^\]\n]*)\]\s*)?" + _SEVERITY + r":\s+" + _BODY
    ),
    # The prefix the OpenObserve DBM docs recommend, and the one the reference
    # collector rig runs: `%m [%p] %q%u@%d app=%a vxid=%v txid=%x line=%l qid=%Q `.
    # `qid=` appears only when `compute_query_id = on`; it is the join key that
    # survives statement-text normalization, so it is worth parsing when present.
    re.compile(
        _TS + r"\s+\[(?P<pg_pid>\d+)\]\s*"
        r"(?:(?P<pg_user>[^@\s]+)@(?P<pg_db>\S+)\s+app=(?P<pg_app>\S*)\s+"
        r"vxid=(?P<pg_vxid>\S*)\s+txid=(?P<pg_txid>\S*)\s+line=(?P<pg_line>\d+)\s+"
        r"(?:qid=(?P<pg_query_id>-?\d+)\s+)?)?" + _SEVERITY + r":\s+" + _BODY
    ),
    # Azure's ACTUAL default, `%t-%c-`:
    #   2023-03-02 02:59:04 UTC-63f881b7.10b-LOG:  checkpoint complete: ...
    # It carries no user, database or application at all — see
    # SESSION_AWARE_PATTERNS below for what that costs and how it is reported.
    re.compile(
        r"(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? [^-\s]+)-"
        r"(?P<pg_session_id>[0-9A-Fa-f]+\.[0-9A-Fa-f]+)-"
        + _SEVERITY + r":\s+" + _BODY
    ),
    # Last resort for a custom `log_line_prefix`: find the severity token and
    # split there. Anchored to a closed list of severities so an arbitrary
    # `WORD:` inside the prefix cannot be mistaken for one.
    re.compile(
        _TS + r"\s+(?P<pg_prefix_rest>[^\n]*?)"
        r"(?P<pg_severity>LOG|ERROR|FATAL|PANIC|WARNING|NOTICE|INFO|"
        r"DEBUG[1-5]|DETAIL|HINT|CONTEXT|STATEMENT):\s+" + _BODY
    ),
)

# Which of the patterns above can actually yield user/database/application.
#
# This matters more than it looks. Azure's default `log_line_prefix` is `%t-%c-`,
# which carries NONE of them, and the generic fallback cannot recover them from
# an arbitrary prefix either. `o2_dbm_database` comes from `pg_db` and has no
# other source in the Azure envelope, so on an untouched server the Database
# Monitoring database dimension would be empty on every row — while the pipeline
# looked healthy, because the line still parsed. `main` counts these and says so.
SESSION_AWARE_PATTERNS = frozenset((0, 1))

# Values Postgres writes when a field is not yet known. Storing them would make
# `o2_dbm_database` the literal string "[unknown]" for every pre-auth line.
_UNKNOWN_VALUES = frozenset(("", "[unknown]", "unknown"))

# ---------------------------------------------------------------------------
# Event classification -- the `filelog/pg` router, in its original order.
#
# ORDER IS LOad-BEARING in one place: an auto_explain entry begins
# `duration: N.NNN ms  plan:`, so it also matches the bare `^duration:` route.
# The explain test must run first or every plan is filed as a statement
# duration and the executed-plan pages stay empty.
# ---------------------------------------------------------------------------
RE_DEADLOCK_HEAD = re.compile(r"^deadlock detected")
RE_DEADLOCK_DETAIL = re.compile(r"waits for [^\n]* blocked by process")
RE_LOCK_WAIT = re.compile(r"still waiting for")
RE_LOCK_ACQUIRED = re.compile(r"acquired [^\n]*Lock on")
RE_TEMP_FILE = re.compile(r"^temporary file:")
RE_EXPLAIN_HEAD = re.compile(r"^duration:\s*[\d.]+\s*ms\s+plan:")
RE_DURATION_HEAD = re.compile(r"^duration:")

# Per-event field extraction. Group names are the collector's attribute names.
RE_EXPLAIN_DURATION = re.compile(r"^duration:\s*(?P<ae_duration_ms>[\d.]+)\s*ms\s+plan:")
# The plan document travels as ONE STRING attribute. Emitting it as a nested
# object instead would make the record non-scalar, which the DBM canonicalizer
# refuses (and which can reject the whole ingest batch).
RE_EXPLAIN_PLAN = re.compile(r"plan:\s*(?P<ae_plan_json>\{[\s\S]*\})\s*$")
RE_STATEMENT = re.compile(
    r"^duration:\s*(?P<stmt_duration_ms>[\d.]+)\s*ms\s+"
    r"(?P<stmt_kind>statement|execute [^:]*|parse [^:]*|bind [^:]*):\s+"
    r"(?P<stmt_text>[\s\S]*)$"
)
RE_LOCK_WAIT_FIELDS = re.compile(
    r"process (?P<lw_pid>\d+) still waiting for (?P<lw_lock_mode>\S+) on "
    r"(?P<lw_lock_target>[^\n]+?) after (?P<lw_wait_ms>[\d.]+) ms"
)
RE_LOCK_ACQ_FIELDS = re.compile(
    r"process (?P<lw_pid>\d+) acquired (?P<lw_lock_mode>\S+) on "
    r"(?P<lw_lock_target>[^\n]+?) after (?P<lw_wait_ms>[\d.]+) ms"
)
RE_TEMP_FILE_FIELDS = re.compile(
    r'temporary file: path "(?P<tmp_path>[^"]+)", size (?P<tmp_size_bytes>\d+)'
)
RE_DL_FIRST_EDGE = re.compile(
    r"Process (?P<dl_waiter_pid>\d+) waits for (?P<dl_lock_mode>\S+) on "
    r"(?P<dl_lock_target>[^;]+); blocked by process (?P<dl_blocker_pid>\d+)"
)
RE_DL_SECOND_EDGE = re.compile(
    r"blocked by process \d+\.\s*\n\s*"
    r"Process (?P<dl_waiter2_pid>\d+) waits for (?P<dl_lock_mode2>\S+) on "
    r"(?P<dl_lock_target2>[^;]+); blocked by process (?P<dl_blocker2_pid>\d+)"
)
RE_DL_STMT_1 = re.compile(r"Process (?P<dl_p1>\d+): (?P<dl_query_1>[^\n]+)")
RE_DL_STMT_2 = re.compile(
    r"Process \d+: [^\n]+\n\s*Process (?P<dl_p2>\d+): (?P<dl_query_2>[^\n]+)"
)

# Which captured groups are numeric. The reference collector emits every
# capture as a string and OpenObserve parses both forms, but a column that
# arrives as text on one record and as a number on another is exactly what
# wedges the DBM rollup -- so every numeric field is emitted as a JSON number
# here, always.
_INT_FIELDS = frozenset(
    (
        "pg_pid",
        "pg_line",
        "lw_pid",
        "tmp_size_bytes",
        "deadlock_victim_pid",
        "dl_waiter_pid",
        "dl_blocker_pid",
        "dl_waiter2_pid",
        "dl_blocker2_pid",
        "dl_p1",
        "dl_p2",
    )
)
_FLOAT_FIELDS = frozenset(("ae_duration_ms", "stmt_duration_ms", "lw_wait_ms"))

# Timezone abbreviations Postgres may print that map unambiguously to UTC.
# Anything else (`log_timezone` set to a named zone) is not resolvable without
# a tz database, so the Azure envelope's own `time` is used instead.
_UTC_NAMES = frozenset(("UTC", "GMT", "Z", "UCT", "ZULU"))
_RE_NUMERIC_OFFSET = re.compile(r"^([+-])(\d{2})(?::?(\d{2}))?$")

# The DBM stream is FIXED, not configurable. Every OpenObserve Database
# Monitoring read is issued against `_o2_dbm_server`; a record delivered
# anywhere else ingests and canonicalizes perfectly and is still invisible to
# every DBM page. Making this a knob only ever produces that silent failure.
DBM_STREAM = "_o2_dbm_server"
DEFAULT_OTHER_STREAM = "azure_postgresql_logs"
DEFAULT_POSTGRES_DNS_SUFFIX = "postgres.database.azure.com"

# Keep each POST comfortably below OpenObserve's default request-size ceiling.
# auto_explain documents are large, and Azure caps a single log event at 64 KB,
# so a batch of a few hundred plans can otherwise exceed it.
MAX_PAYLOAD_BYTES = 4 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 30
HTTP_MAX_ATTEMPTS = 3
RETRYABLE_STATUS = frozenset((408, 429, 500, 502, 503, 504))


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _clean(value):
    """Normalize a captured prefix field, dropping Postgres' unknown markers."""
    if value is None:
        return None
    value = value.strip()
    return None if value in _UNKNOWN_VALUES else value


def _to_micros(dt: datetime) -> int:
    return int(dt.timestamp() * 1_000_000)


def _parse_azure_time(value):
    """Parse the Azure envelope's `time` (RFC 3339, always UTC) to epoch micros."""
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    # Python's parser accepts at most 6 fractional digits; Azure sometimes
    # emits 7 (.NET "round-trip" format).
    text = re.sub(r"\.(\d{6})\d+", r".\1", text)
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return _to_micros(dt)


def _parse_pg_timestamp(value):
    """Parse a Postgres `%m`/`%t` timestamp to epoch micros.

    Returns None when the trailing timezone token is a named zone this function
    cannot resolve -- guessing UTC there would silently shift every row.
    """
    if not value:
        return None
    # Only the ISO date/time separator is normalized -- a blanket replace would
    # turn the "UTC" zone token, which is the one Azure actually emits, into
    # "U C" and send every row down the un-resolvable-zone path.
    parts = re.sub(r"^(\d{4}-\d{2}-\d{2})T", r"\1 ", value.strip()).split()
    # `%m` yields "<date> <time> <zone>"; a custom prefix may omit the zone.
    if len(parts) < 2:
        return None
    stamp = parts[0] + " " + parts[1]
    zone = parts[2] if len(parts) > 2 else None

    try:
        if "." in stamp:
            base, frac = stamp.split(".", 1)
            dt = datetime.strptime(base, "%Y-%m-%d %H:%M:%S")
            dt = dt.replace(microsecond=int((frac + "000000")[:6]))
        else:
            dt = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None

    if zone is None:
        return None
    zone = zone.upper()
    if zone in _UTC_NAMES:
        return _to_micros(dt.replace(tzinfo=timezone.utc))
    match = _RE_NUMERIC_OFFSET.match(zone)
    if match:
        sign = -1 if match.group(1) == "-" else 1
        offset = timedelta(hours=int(match.group(2)), minutes=int(match.group(3) or 0))
        return _to_micros(dt.replace(tzinfo=timezone(sign * offset)))
    return None


def _server_name_from_resource_id(resource_id):
    """Flexible Server leaves `LogicalServerName` empty; the resource ID has it."""
    if not resource_id:
        return None
    parts = [p for p in resource_id.split("/") if p]
    return parts[-1].lower() if parts else None


def _reconstruct_line(properties, is_flexible_server):
    """Return the full Postgres log line for one Azure record.

    Flexible Server puts the entire line -- prefix, severity and message --
    in `properties.message` and leaves `properties.prefix` empty. Single Server
    splits them across `prefix`, `errorLevel` and `message`, so they have to be
    glued back together before the prefix patterns can match.
    """
    message = properties.get("message") or ""
    prefix = properties.get("prefix") or ""
    if is_flexible_server or not prefix:
        return message
    level = properties.get("errorLevel") or "LOG"
    return "{}{}:  {}".format(prefix, level, message)


def _match_line(line):
    """Match a log line against the known prefix shapes.

    Returns `(match, pattern_index)`; the index tells the caller whether the
    prefix that matched can carry user/database/application at all.
    """
    for index, pattern in enumerate(PREFIX_PATTERNS):
        match = pattern.match(line)
        if match:
            return match, index
    return None, -1


def _detail_line(parent_line, detail):
    """Rebuild the standalone DETAIL entry Flexible Server folds into `detail`.

    Reuses the parent's own prefix verbatim -- same timestamp, pid and session
    fields -- so the pair correlates exactly as the two separate log entries an
    on-host tailer would have produced.
    """
    match, _ = _match_line(parent_line)
    if match is None:
        return None
    return parent_line[: match.start("pg_severity")] + "DETAIL:  " + detail


def _classify(severity, message):
    """Return the `o2_pg_event` tag for one message, mirroring `filelog/pg`."""
    if RE_DEADLOCK_HEAD.search(message):
        return "deadlock"
    if severity == "DETAIL" and RE_DEADLOCK_DETAIL.search(message):
        return "deadlock"
    if RE_LOCK_WAIT.search(message):
        return "lock_wait"
    if RE_LOCK_ACQUIRED.search(message):
        return "lock_acquired"
    if RE_TEMP_FILE.search(message):
        return "temp_file"
    # Before the bare `^duration:` test -- see the ORDER note above.
    if RE_EXPLAIN_HEAD.search(message):
        return "explain"
    if RE_DURATION_HEAD.search(message):
        return "statement_duration"
    return "other"


def _apply(record, pattern, message):
    """Merge a regex's named groups into `record`, coercing numeric fields.

    Mirrors the collector's `on_error: send`: a regex that does not match
    leaves the record untouched rather than dropping it.
    """
    match = pattern.search(message)
    if not match:
        return False
    for key, value in match.groupdict().items():
        if value is None:
            continue
        value = value.strip()
        if not value:
            continue
        record[key] = _coerce(key, value)
    return True


def _coerce(key, value):
    try:
        if key in _INT_FIELDS:
            return int(value)
        if key in _FLOAT_FIELDS:
            return float(value)
    except ValueError:
        return value
    return value


def _build_record(line, envelope, properties, stream_context):
    """Turn one reconstructed Postgres log line into one flat OpenObserve record.

    Every value is a scalar: the DBM canonicalizer requires it, and a nested
    value can reject the whole ingest batch.
    """
    match, pattern_index = _match_line(line)
    if match is None:
        return None
    fields = match.groupdict()
    stream_context["session_aware"] = pattern_index in SESSION_AWARE_PATTERNS

    message = fields.get("pg_message") or ""
    severity = (fields.get("pg_severity") or "").upper()

    record = {
        "body": line,
        "pg_severity": severity,
        "pg_message": message,
        # `detect_engine` reads this first; without it a record with no `pg_*`
        # field at all would have a null engine and drop out of the `?system=`
        # filter.
        "db_system_name": "postgresql",
        # Matches the collector's `transform/tag_source`.
        "o2_vantage": "server",
        # Deliberately NOT under `o2_` -- that namespace belongs to OpenObserve,
        # and an unrecognized tag there is something the ingest path reasons
        # about. This is ours, so it stays in the `az_` provenance namespace.
        "az_ingest_source": "azure-eventhub",
    }
    for key in ("pg_pid", "pg_user", "pg_db", "pg_app", "pg_vxid", "pg_txid",
                "pg_line", "pg_query_id", "pg_session_id"):
        value = _clean(fields.get(key))
        if value is not None:
            record[key] = _coerce(key, value)

    # Azure puts the backend pid in the envelope on EVERY record, whatever
    # `log_line_prefix` is set to. Under the Azure default (`%t-%c-`) the prefix
    # carries no pid at all, and `pg_pid` is what the deadlock and
    # statement-duration canonicalizers read for the session.
    if "pg_pid" not in record:
        process_id = properties.get("processId")
        if isinstance(process_id, (int, float)) and not isinstance(process_id, bool):
            record["pg_pid"] = int(process_id)
        elif isinstance(process_id, str) and process_id.strip().isdigit():
            record["pg_pid"] = int(process_id.strip())

    # WHICH SERVER these rows came from -- `detect_instance`'s first alias, and
    # the dimension the Database Monitoring instance filter matches on. A null
    # here silently empties every DBM tab the moment an operator picks a value.
    if stream_context["instance"]:
        record["server_address"] = stream_context["instance"]
        record["host_name"] = stream_context["instance"]

    # Azure provenance. Prefixed `az_` so none of these can collide with a name
    # the canonicalizer's detectors read (`schema_name` and `database` are both
    # live aliases for `o2_dbm_database`).
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
    if stream_context["server_name"]:
        record["az_server_name"] = stream_context["server_name"]
    # Flexible Server does not emit HINT/CONTEXT/STATEMENT/QUERY as their own
    # log events the way a self-hosted server does — it hangs them off the
    # parent record as these fields. Carrying them keeps the evidence that an
    # on-host tailer would have picked up from the following log lines.
    for src, dst in (
        ("errorLevel", "az_error_level"),
        ("sqlerrcode", "az_sqlerrcode"),
        ("domain", "az_domain"),
        ("detail", "az_detail"),
        ("detail_log", "az_detail_log"),
        ("statement", "az_statement"),
        ("query", "az_query"),
        ("hint", "az_hint"),
        ("context", "az_context"),
        ("constraint_name", "az_constraint_name"),
        ("backend_type", "az_backend_type"),
        ("schemaName", "az_schema_name"),
        ("tableName", "az_table_name"),
        ("columnName", "az_column_name"),
        ("datatypeName", "az_datatype_name"),
    ):
        value = properties.get(src)
        if isinstance(value, (str, int, float)) and value != "":
            record[dst] = value

    # `properties.timestamp` first: Azure stamps it on every record with
    # millisecond precision and an explicit zone, whereas the in-line `%t`
    # prefix has only second precision and a custom prefix may omit the zone
    # entirely. The envelope's own `time` is the last resort — it is when Azure
    # ingested the event, not when Postgres logged it.
    timestamp = _parse_pg_timestamp(properties.get("timestamp"))
    if timestamp is None:
        timestamp = _parse_pg_timestamp(fields.get("ts"))
    if timestamp is None:
        timestamp = _parse_azure_time(envelope.get("time"))
    if timestamp is None:
        timestamp = int(time.time() * 1_000_000)
    record["_timestamp"] = timestamp

    # Classification + per-event extraction, in the collector's order.
    event = _classify(severity, message)
    record["o2_pg_event"] = event

    if event == "deadlock":
        # The victim is the backend that reported the error: Postgres aborts it.
        # Only when the pid is actually known — a literal null here is read as a
        # present-but-empty column rather than as "no victim recorded".
        if record.get("pg_pid") is not None:
            record["deadlock_victim_pid"] = record["pg_pid"]
        _apply(record, RE_DL_FIRST_EDGE, message)
        _apply(record, RE_DL_SECOND_EDGE, message)
        _apply(record, RE_DL_STMT_1, message)
        _apply(record, RE_DL_STMT_2, message)
        record["o2_capability"] = "deadlock_event"
        record["o2_deadlock_raw"] = record.pop("pg_message")
    elif event == "explain":
        _apply(record, RE_EXPLAIN_DURATION, message)
        # The regex is anchored on `plan: {` ... `}` so that under
        # `auto_explain.log_format = text`, or on a document Azure truncated at
        # its 65 KB event ceiling, no `ae_plan_json` is set at all rather than
        # half a plan. The counter in `main` reports how often that happens.
        _apply(record, RE_EXPLAIN_PLAN, message)
        record["o2_capability"] = "explain_event"
        record["o2_explain_raw"] = record.pop("pg_message")
    elif event == "statement_duration":
        _apply(record, RE_STATEMENT, message)
        # Under the extended protocol one client call logs up to three lines --
        # parse, bind and execute. OpenObserve counts only `statement` and
        # `execute`, so forwarding the other two would put two uncanonicalizable
        # rows into the DBM stream for every one that counts. They are demoted
        # here rather than at the classifier so `stmt_kind` is parsed first.
        kind = record.get("stmt_kind") or ""
        if kind and kind != "statement" and not kind.startswith("execute"):
            record["o2_pg_event"] = event = "other"
    elif event == "lock_wait":
        _apply(record, RE_LOCK_WAIT_FIELDS, message)
    elif event == "lock_acquired":
        _apply(record, RE_LOCK_ACQ_FIELDS, message)
    elif event == "temp_file":
        _apply(record, RE_TEMP_FILE_FIELDS, message)

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
    not retryable and would otherwise look like an unexplained failure. Azure's
    65 KB per-event ceiling makes this unreachable in practice.
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


def _post(url, access_key, records):
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
                logging.info(
                    "Sent %d records to OpenObserve (%d bytes). HTTP %s",
                    len(records), len(payload), response.status,
                )
                return
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code not in RETRYABLE_STATUS:
                # The response body is where OpenObserve says WHY -- a schema
                # conflict on the stream, a bad org, a rejected batch. Without
                # it a 400 reads as an unexplained outage.
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
    # Raising fails the Event Hub batch so the runtime retries it rather than
    # advancing the checkpoint past records that were never delivered.
    raise last_error if last_error else RuntimeError("OpenObserve POST failed")


def main(events) -> None:
    base_url = (os.environ.get("OPENOBSERVE_BASE_URL", "") or "").rstrip("/")
    organization = os.environ.get("OPENOBSERVE_ORGANIZATION", "default")
    access_key = os.environ.get("OPENOBSERVE_ACCESS_KEY", "")
    other_stream = os.environ.get("OTHER_STREAM_NAME", "") or DEFAULT_OTHER_STREAM
    forward_other = _env_flag("FORWARD_NON_DBM_LOGS", False)
    instance_override = (os.environ.get("POSTGRES_SERVER_ADDRESS", "") or "").strip()
    dns_suffix = (
        os.environ.get("POSTGRES_DNS_SUFFIX", "") or DEFAULT_POSTGRES_DNS_SUFFIX
    ).strip().lstrip(".")

    if not base_url or not access_key:
        logging.error(
            "Missing OPENOBSERVE_BASE_URL or OPENOBSERVE_ACCESS_KEY; nothing forwarded"
        )
        return

    dbm_url = "{}/api/{}/{}/_json".format(base_url, organization, DBM_STREAM)
    other_url = "{}/api/{}/{}/_json".format(base_url, organization, other_stream)

    dbm_records = []
    other_records = []
    unparsed = 0
    plans_without_json = 0
    prefix_without_session = 0

    for event in events if isinstance(events, list) else [events]:
        try:
            azure_records = _records_from_message(_event_body(event))
        except Exception as exc:  # noqa: BLE001
            logging.error("Error reading Event Hub message: %s", exc)
            continue

        for envelope in azure_records:
            if not isinstance(envelope, dict):
                continue
            properties = envelope.get("properties")
            if not isinstance(properties, dict):
                properties = {}

            server_name = (
                envelope.get("LogicalServerName")
                or _server_name_from_resource_id(envelope.get("resourceId"))
            )
            if server_name:
                server_name = server_name.lower()
            is_flexible = "FLEXIBLESERVERS" in (envelope.get("resourceId") or "").upper()
            instance = instance_override or (
                "{}.{}".format(server_name, dns_suffix) if server_name and dns_suffix
                else server_name
            )
            context = {"server_name": server_name, "instance": instance}

            # Flexible Server does not emit DETAIL/HINT/CONTEXT as their own log
            # events; it folds DETAIL into `properties.detail` on the parent
            # record. A deadlock's wait cycle and every participant's SQL live
            # there, so it is re-emitted as the separate DETAIL entry an on-host
            # tailer would have seen -- correlated to the parent by pid.
            parent_line = _reconstruct_line(properties, is_flexible)
            lines = [parent_line]
            detail = properties.get("detail")
            if isinstance(detail, str) and detail.strip():
                synthesized = _detail_line(parent_line, detail)
                if synthesized:
                    lines.append(synthesized)
                    # The text now lives on the DETAIL record's own body, so
                    # drop `az_detail` from both: keeping it would store a
                    # deadlock's whole wait cycle and every participant's SQL
                    # three times over. When the parent could NOT be parsed
                    # no DETAIL record exists, and `az_detail` is preserved
                    # below so the text is never lost.
                    properties = dict(properties)
                    properties.pop("detail", None)

            for line in lines:
                if not line.strip():
                    continue
                record = _build_record(line, envelope, properties, context)
                if record is None:
                    unparsed += 1
                    continue
                event_tag = record.get("o2_pg_event")
                if event_tag == "explain" and "ae_plan_json" not in record:
                    plans_without_json += 1
                if not context.get("session_aware"):
                    prefix_without_session += 1
                if event_tag and event_tag != "other":
                    dbm_records.append(record)
                elif forward_other:
                    other_records.append(record)

    if unparsed:
        # A non-zero count here almost always means `log_line_prefix` was
        # changed to a shape none of PREFIX_PATTERNS knows.
        logging.warning("%d log line(s) did not match any log_line_prefix pattern", unparsed)
    if prefix_without_session:
        # The silent-failure case this counter exists for. Azure's default
        # `log_line_prefix` (`%t-%c-`) parses cleanly but carries no user,
        # database or application, and the envelope has no other source for
        # them -- so o2_dbm_database is null on every row and the Database
        # Monitoring database filter matches nothing. Without this line the
        # pipeline looks entirely healthy while that is happening.
        logging.warning(
            "%d record(s) came from a log_line_prefix carrying no user/db/app; "
            "o2_dbm_database will be empty. Set log_line_prefix to "
            "'%%m [%%p] %%q[user=%%u,db=%%d,app=%%a] ' on the server",
            prefix_without_session,
        )
    if plans_without_json:
        logging.warning(
            "%d auto_explain entr(ies) carried no JSON plan document; set "
            "auto_explain.log_format = json on the server",
            plans_without_json,
        )

    for batch in _chunks(dbm_records):
        _post(dbm_url, access_key, batch)
    for batch in _chunks(other_records):
        _post(other_url, access_key, batch)

    logging.info(
        "Forwarded %d DBM record(s) to %s and %d other record(s)",
        len(dbm_records), DBM_STREAM, len(other_records),
    )
