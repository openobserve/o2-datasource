# Codex — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Codex** panel should render.

> ⚠ **Important** — Codex `exec` mode emits OpenTelemetry **logs and
> metrics**, NOT traces. The integration shows up in the Logs tab in
> OpenObserve, not the Traces tab. The panel copy should make this clear.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | OpenAI Codex |
| Category | AI / Agents |
| Icon | `codex.svg` |
| Tagline | Per-conversation logs from every Codex CLI session |
| Prerequisites | Codex CLI ≥ 0.135, Python 3.9+ (installer only) |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/agents/codex/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:**

1. Validates flags, finds Python 3.9+ with pip.
2. Writes a sentinel-delimited `[otel.exporter.otlp-http]` block into
   `~/.codex/config.toml` pointing at OpenObserve's logs endpoint
   (`<url>/api/<org>/v1/logs`). Existing `config.toml` content is
   preserved; the file is backed up to `<file>.bak.<unix-ts>`.

Re-running updates the block in place. The block looks like:

```toml
# >>> openobserve-otel >>>
[otel.exporter.otlp-http]
protocol = "binary"
endpoint = "https://api.openobserve.ai/api/<org>/v1/logs"
headers = { Authorization = "Basic <token>", organization = "<org>", "stream-name" = "default" }
# <<< openobserve-otel <<<
```

## Section 2 — Verify

```bash
codex exec --skip-git-repo-check "What's the capital of France?"
```

Open OpenObserve, go to the **Logs** tab → filter `service_name =
codex_exec`. You'll see entries like `event.name="codex.conversation_starts"`,
`event.name="codex.startup_phase"`, model name, prompt, response, token
counts. One short session produces ~20-30 log records.

E2E example: a single `codex exec "say ok"` produced 29 log records in the
default stream.

## Section 3 — What gets captured

Codex emits structured logs via OTLP-HTTP for every internal event. Common
fields:

| Field | Source |
|---|---|
| `service_name` | always `codex_exec` (for the `exec` binary mode) |
| `event.name` | `codex.conversation_starts`, `codex.startup_phase`, `codex.message_sent`, etc. |
| `conversation.id` | UUID per Codex session |
| `app.version` | Codex CLI version |
| `model` | the model used (e.g. `gpt-5.5`) |
| `auth_mode` | `ApiKey` or `ChatGPT` |
| `event.timestamp` | event time (RFC 3339) |
| `body_content` | for prompt/response events |

Set `[otel] log_user_prompt = true` in `~/.codex/config.toml` to include the
prompt text — disabled by default for privacy. The installer doesn't set
this; the user opts in by editing the file.

## Section 4 — Limitations

| Limitation | Workaround |
|---|---|
| **No traces** in exec mode | Use the Logs tab, not Traces, in OpenObserve |
| Metrics 404 silently | Codex sends metrics to the same endpoint as logs, OpenObserve rejects them (acceptable noise) |
| Authentication requires `codex login` first | Run `printenv OPENAI_API_KEY \| codex login --with-api-key` once per host |

## Section 5 — Troubleshooting

| Symptom | Fix |
|---|---|
| `Error loading config.toml: unknown variant 'otlp'` | You manually edited config.toml — let the installer write the block |
| `Error loading config.toml: missing field 'protocol'` | Same as above |
| `unexpected status 401 Unauthorized` from OpenAI | Run `codex login --with-api-key` |
| `Not inside a trusted directory` | Pass `--skip-git-repo-check` or run codex inside a git repo |
| No logs appear after a session | Verify config.toml has the block; check `tail ~/.codex/logs/codex-*.log` |

---

## Panel implementation notes

- **The verify link must point at the Logs tab, not Traces.** Filter
  `service_name = codex_exec`.
- If the user has set `log_user_prompt = true`, show a privacy banner.
- The "what's captured" section is the most useful differentiation from
  Claude Code (which is trace-shaped). Codex users see event-stream logs.

## Reference

Full integration docs (none in `openobserve-docs` yet — needs writing).
Live installer:
[openobserve-telemetry-installers/agents/codex/install.sh](../../openobserve-telemetry-installers/agents/codex/install.sh)
