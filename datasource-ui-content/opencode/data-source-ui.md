# OpenCode

**AI / Agents · CLI agent** — Trace every OpenCode session: agent steps, tool calls, file ops.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/opencode/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs the OpenCode OTel telemetry plugin and writes its config (registers the plugin and the `OTEL_EXPORTER_OTLP_*` env file).

## 2. Use OpenCode

Run any OpenCode command, e.g.:

```bash
opencode run "say hi"
```

## 3. Check OpenObserve

Open **Traces** and filter `service_name=opencode`. You'll see a span per OpenCode run.

---

Run into issues? See the [docs](https://openobserve.ai/docs/) or reach out to us on [Slack](https://short.openobserve.ai/community).
