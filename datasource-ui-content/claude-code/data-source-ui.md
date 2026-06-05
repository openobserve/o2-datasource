# Claude Code — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → Claude Code** panel should render.

This is a CLI-agent integration — different shape from the framework cards.
The user doesn't paste anything into their app; the installer registers a
Stop hook in their Claude Code config, and traces appear automatically for
every session.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | Claude Code |
| Category | AI / Agents |
| Icon | `claude-code.svg` |
| Tagline | Trace every Claude Code conversation turn — no code changes |
| Prerequisites | Python 3.9+, Claude Code CLI installed |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/agents/claude-code/install.sh | bash -s -- \
  --url={url} \
  --org={org} \
  --token="Basic {token}" \
  --scope=global
```

**Scope options:**
- `--scope=global` → writes to `~/.claude/settings.json` (all projects)
- `--scope=project` → writes to `./.claude/settings.local.json` (this dir only)

**What this does:**

1. Installs `openobserve-telemetry-sdk` via pip (PEP 668 fallback handled).
2. Copies `openobserve_hooks.py` (~580-line Python hook) into
   `~/.claude/hooks/`.
3. Merges into the settings file: adds a `Stop` hook entry + the env vars
   `TRACE_TO_OPENOBSERVE=true`, `OPENOBSERVE_URL/ORG/AUTH_TOKEN`. Existing
   settings preserved; the file is backed up to `<file>.bak.<unix-ts>`.

Idempotent — re-running updates env values in place, never duplicates the
hook registration.

## Section 2 — Verify

Restart any open Claude Code sessions (or start a new one), ask Claude
anything trivial. Then:

```bash
tail -f ~/.claude/state/openobserve_hook.log
# look for: "Processed N turns in X.XXs"
```

In the OpenObserve UI: Traces tab → filter `service.name = claude-code`.
Each conversation turn produces a tree:

```
Claude Code - Turn N
├── Claude Response            (LLM call, model + token counts)
└── Tool: <tool_name>          (one per tool use)
```

E2E example: a single `claude --print "Reply with: ok"` produced 2 spans
(turn + LLM call) within ~10ms of session end.

## Section 3 — Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/agents/claude-code/uninstall.sh | bash -s -- --scope=global
```

Default: only strips the OpenObserve entries from the settings file. Pass
`--remove-hook-script` to also delete the hook script, or `--remove-all` for
a full cleanup including state files.

## Section 4 — What gets captured

| Attribute | Source |
|---|---|
| `service.name` | hard-coded `claude-code` |
| `session.id` | from each Claude Code session |
| `claude_code.turn_number` | conversation turn index |
| `gen_ai.request.model` | the Claude model in use |
| `gen_ai.usage.input_tokens` | tokens read by Claude |
| `gen_ai.usage.output_tokens` | tokens generated |
| `gen_ai.usage.cache_read_tokens` / `cache_write_tokens` | prompt cache stats |
| `gen_ai.input.messages` / `output.messages` | user prompt + Claude reply (truncated to 20k chars by default) |
| `gen_ai.tool.name` / `tool.call.arguments` / `tool.call.result` | per tool use |
| `claude_code.transcript_path` | the JSONL file the hook reads from |

System prompts are not part of Claude Code's conversation transcripts —
they're not in the traces.

## Section 5 — Troubleshooting

| Symptom | Fix |
|---|---|
| No traces appear, no log entries | Stop hook not registered — check `~/.claude/settings.json` for the openobserve_hooks.py entry |
| Log shows `OPENOBSERVE_AUTH_TOKEN not set; exiting` | Env vars not in settings.json — re-run the installer |
| Log shows `Failed to initialize OpenObserve traces` | URL/token wrong, or OpenObserve unreachable from the host |
| Same session.id produces duplicate spans | Don't run two installers writing to the same hook — uninstall one |

---

## Panel implementation notes

- This is the simplest CLI-agent UX in the set — one command, one restart,
  done. The panel should emphasize "no app changes needed".
- The "Verify" section could optionally trigger a `claude --print "say ok"`
  via a "Send test session" button if the UI can run shell commands on the
  user's machine.

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/claude-code-tracing.md](../../openobserve-docs/docs/integration/ai/claude-code-tracing.md)
