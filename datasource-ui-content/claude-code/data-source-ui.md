# Claude Code

**AI / Agents · CLI agent** — trace every Claude Code conversation turn, no code changes.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/claude-code/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}" \
  --scope=global
```

Registers a `Stop` hook and writes the OpenObserve OTel config into Claude Code's `settings.json`.

## 2. Use Claude Code

Just use Claude Code normally — start a session and run a turn in any project. The `Stop` hook ships a trace automatically each turn.

## 3. Check OpenObserve

Open **Traces** and filter `service.name=claude-code`. You'll see a span tree per turn (tool calls, model usage).

## 4. Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/claude-code/uninstall.sh | bash -s -- --scope=global
```

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/claude-code-tracing/) or reach out to us on [Slack](https://short.openobserve.ai/community).
