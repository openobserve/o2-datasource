# OpenCode — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → OpenCode** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | OpenCode |
| Category | AI / Agents |
| Icon | `opencode.svg` |
| Tagline | Trace every OpenCode session — agent steps, tool calls, file ops |
| Prerequisites | Node 18+, OpenCode CLI, Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/agents/opencode/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:**

1. `npm install -g @devtheops/opencode-plugin-otel` — installs the OTel
   plugin globally. No build step required (npm-published).
2. Merges `~/.config/opencode/opencode.jsonc` to register the plugin by
   package name (`"plugin": ["@devtheops/opencode-plugin-otel"]`).
3. Writes `~/.config/opencode/openobserve.env` with the standard
   `OTEL_EXPORTER_OTLP_*` environment variables pointing at your
   OpenObserve instance.

You then **source** the env file before running OpenCode:

```bash
source ~/.config/opencode/openobserve.env && opencode
```

Or add to your shell rc once:

```bash
[ -f ~/.config/opencode/openobserve.env ] && source ~/.config/opencode/openobserve.env
```

## Section 2 — Verify

Run any OpenCode session:

```bash
source ~/.config/opencode/openobserve.env
opencode run "say ok" --model openai/gpt-4o-mini
```

Open OpenObserve, **Traces** tab → filter `service_name = opencode`.

E2E example: a single `opencode run "say ok"` produced **50 spans**:
`Provider.getModel`, `Session.updateMessage`, `SyncEvent.run`,
`SessionSummary.computeDiff`, `FileSystem.writeWithDirs`, and many more
internal OpenCode events.

## Section 3 — What gets captured

| Attribute | Source |
|---|---|
| `service_name` | always `opencode` |
| Span names | `Provider.*`, `Session.*`, `Tool.*`, `FileSystem.*`, `SyncEvent.*`, `SessionSummary.*` |
| Model invocations | one span per `Provider.getModel` + `Provider.execute` |
| Tool calls | one span per tool with args + result |
| File operations | path + diff for write/edit ops |
| Session lifecycle | start, update, summarize, end |

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: @devtheops/opencode-plugin-otel` | `npm install -g @devtheops/opencode-plugin-otel` (or re-run installer) |
| No spans appear | Make sure `openobserve.env` is sourced before launching opencode |
| Spans go to wrong endpoint | Check `OTEL_EXPORTER_OTLP_ENDPOINT` in `openobserve.env` |
| Plugin loaded but no spans | Confirm `experimental.openTelemetry` is NOT set — DEVtheOPS plugin doesn't need it |

---

## Panel implementation notes

- Same template + copy-button as other agent cards.
- **Tip** for the user: env-var sourcing is a one-time-per-shell step.
  Consider including the rc-snippet in a copy-able block too.
- npm install needs network at first run — the panel could detect offline
  and warn.

## Reference

Live installer:
[openobserve-telemetry-installers/agents/opencode/install.sh](../../openobserve-telemetry-installers/agents/opencode/install.sh)

Plugin: <https://github.com/DEVtheOPS/opencode-plugin-otel>
