# AI integrations

One-shot bash installers that wire OpenObserve telemetry into AI frameworks,
SDKs, model providers, and CLI agents. Same `curl | bash` shape as the
sibling [k8s/](../k8s/) installers.

```
.
├── frameworks/          # 10 Python framework/SDK/provider integrations, one setup.sh
├── agents/              # CLI-agent installers (one install.sh per agent)
│   ├── claude-code/     # Stop hook + settings.json
│   ├── codex/           # writes [otel.exporter.otlp-http] in ~/.codex/config.toml
│   ├── opencode/        # npm-install + writes opencode.jsonc
│   └── cursor/          # delegates to LangGuard-AI/cursor-otel-hook
└── lib/common.sh        # shared bash helpers, sourced by every installer
```

## Status matrix

| Integration | Type | Status |
|---|---|---|
| `frameworks/openai` | provider | ready |
| `frameworks/anthropic` | provider | ready |
| `frameworks/gemini` | provider | ready |
| `frameworks/langchain` | framework | ready |
| `frameworks/crewai` | framework | ready (note: snippet order is `init → instrumentor` — see `frameworks/integrations.json`) |
| `frameworks/google-adk` | framework | ready |
| `frameworks/claude-agent-sdk` | sdk | ready (manual span wrapping) |
| `frameworks/openai-agents` | framework | ready |
| `frameworks/openrouter` | gateway | ready |
| `frameworks/litellm` | gateway | ready |
| `agents/claude-code` | CLI agent | ready |
| `agents/codex` | CLI agent | ready (emits logs + metrics, not traces) |
| `agents/opencode` | CLI agent | ready |
| `agents/cursor` | CLI agent | ready (smoke only — full e2e requires macOS + Cursor open) |

## Quickstart per integration

### Framework / SDK / provider

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | \
  bash -s -- \
    --integration=openai \
    --url=https://api.openobserve.ai \
    --org=default \
    --token="Basic $(echo -n 'me@example.com:my-pass' | base64)"
```

Run `bash frameworks/setup.sh --help` for all flags. The full list of supported
integrations is the keys in [frameworks/integrations.json](frameworks/integrations.json).

### CLI agent

```bash
# Claude Code (writes hook + settings.json):
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/claude-code/install.sh | \
  bash -s -- --url=... --org=... --token="Basic ..." --scope=global

# Codex (writes [otel] block in ~/.codex/config.toml):
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/codex/install.sh | \
  bash -s -- --url=... --org=... --token="Basic ..."

# OpenCode (clones + builds pai4451/opencode-telemetry-plugin, writes opencode.jsonc):
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/opencode/install.sh | \
  bash -s -- --url=... --org=... --token="Basic ..."

# Cursor (delegates to LangGuard-AI/cursor-otel-hook, writes otel_config.json):
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/cursor/install.sh | \
  bash -s -- --url=... --org=... --token="Basic ..."
```

## Conventions

All installers share the same shape (lifted from the sibling [`k8s/install.sh`](../k8s/install.sh)):

- Flag-style args: `--url=`, `--org=`, `--token=`, `--scope=` etc.
- Colored log helpers via `lib/common.sh`: `print_info / success / warning /
  error`, plus `[Step N/M]` per action.
- Token redaction (`abcd****wxyz`) in all log output.
- `--dry-run` to validate config without changes.
- `--quiet` to suppress info logs.
- `--help` shows usage + examples.
- Backup any modified file to `<file>.bak.<unix-ts>` on first write.
- Idempotent: re-running with same args updates values in place; never adds
  duplicate registrations.
- Errors print the exact remediation command.

Under `curl | bash`, every installer fetches `lib/common.sh` and any
integration data from the same `REPO_RAW` base URL. Override `REPO_RAW=file://...`
for local testing.

## Development

- Reference installer style: [k8s/install.sh](../k8s/install.sh).
- Source of truth for each integration's snippet/packages: the upstream
  OpenObserve docs at
  [openobserve.ai/docs/integration/ai/](https://openobserve.ai/docs/integration/ai/).

Adding a new framework integration:

1. Add the row to [frameworks/integrations.json](frameworks/integrations.json).

No changes to `setup.sh` are needed for new integrations as long as they
follow the standard `(Instrumentor().instrument() ; openobserve_init())`
shape. Manual-span integrations (like `claude-agent-sdk`) need a custom
snippet in `integrations.json`.

Adding a new CLI agent is a full directory: clone the `claude-code/`
structure and swap the settings-file format/path.
