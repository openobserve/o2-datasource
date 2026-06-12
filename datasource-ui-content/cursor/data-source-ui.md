# Cursor

**AI / Agents · CLI agent** — Trace Cursor Agent activity: tool calls, file ops, prompt context.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/cursor/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Bootstraps the upstream [cursor-otel-hook](https://github.com/LangGuard-AI/cursor-otel-hook) and writes the OpenObserve config to `~/.cursor/hooks/otel_config.json`. Restart Cursor afterward. Already have the hook installed? Add `--skip-bootstrap`.

## 2. Use Cursor

Run any prompt in the Cursor IDE as you normally would. The OTel hook ships a trace per request automatically. (Requires the Cursor desktop app.)

## 3. Check OpenObserve

Open **Traces** and filter `service_name=cursor`. You'll see a span per Cursor request.

---

Run into issues? See the [docs](https://openobserve.ai/docs/) or reach out to us on [Slack](https://short.openobserve.ai/community).
