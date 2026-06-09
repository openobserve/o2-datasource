# OpenAI Codex

**AI / Agents · CLI agent** — per-conversation logs from every Codex CLI session.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/codex/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Writes an `[otel.exporter.otlp-http]` block into `~/.codex/config.toml` pointing at OpenObserve's logs endpoint (`<url>/api/<org>/v1/logs`).

## 2. Use Codex

Run any Codex command, e.g.:

```bash
codex exec "say hi"
```

## 3. Check OpenObserve

Codex emits **logs** (not traces) in exec mode. Open **Logs** and filter `service_name=codex_exec`. You'll see a log record per session.

---

Run into issues? See the [docs](https://openobserve.ai/docs/) or reach out to us on [Slack](https://short.openobserve.ai/community).
