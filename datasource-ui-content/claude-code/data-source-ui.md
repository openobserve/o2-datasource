---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: Claude Code
  tagline: Stream Claude Code metrics, events, and traces to OpenObserve — no code changes.
  runtime: CLI agent
  setup_time: ~2 min
  logo: logo.svg
  tone: "#d97757"

# Live detection — "listening for the first event". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). Claude Code's native OTLP
# exporter lands events in the `claude_code` logs stream; metrics land in the
# `claude_code_*` streams and the per-turn span tree under traces. We listen on
# the events stream because it's on by default (traces are beta).
detect:
  stream_type: logs
  stream: claude_code
  # confirmed on ingest: Claude Code sets service_name = 'claude-code' on every signal
  filter: "service_name = 'claude-code'"

doc_url: https://openobserve.ai/docs/integration/ai/claude-code-tracing/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command writes Claude Code's native OpenTelemetry config into `settings.json` — metrics, events, and (beta) traces over OTLP. No hook, no SDK. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/claude-code/install.sh | bash -s -- \
          --url={url} \
          --org={org} \
          --token="Basic {token}" \
          --scope=global

  - title: Use Claude Code
    description: "Start a fresh session and run a turn in any project. Claude Code exports telemetry automatically — every prompt, model request, and tool result ships over OTLP."
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true

  - title: Check OpenObserve
    description: "Open **Logs** and select the `claude_code` stream — you'll see events streaming in. Metrics land in `claude_code_*`; the per-turn span tree is under **Traces**."
    chip: { kind: logs, label: Logs }
    complete_on: detect
    pills:
      - cost & tokens
      - tool decisions
      - model usage


fix_title: "Re-run The Installer And Restart Claude Code"
fix_body: "Telemetry comes from the env block in settings.json, read at session start. If nothing arrives, confirm it's present, then start a fresh session:"
fix_lang: bash
fix_snippet: |
  # confirm the native telemetry env is present
  cat ~/.claude/settings.json | grep CLAUDE_CODE_ENABLE_TELEMETRY

  # if missing, re-run the installer (safe to re-run), then start a new session
troubleshooting:
  - q: "Turns run but no data appears"
    a: "Start a fresh Claude Code session after installing — the env block is read at session start, not mid-session."
  - q: "The env isn't in settings.json"
    a: "Re-run the installer (idempotent). Use `--scope=project` to write to the project's `.claude/settings.local.json` instead."
  - q: "Logs and metrics land but no traces"
    a: "Traces are beta: confirm CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 and OTEL_TRACES_EXPORTER=otlp are set (the installer adds both), then start a new session."
  - q: "Auth errors in the OpenObserve logs"
    a: "The token must be `Basic <base64>` or `Bearer <token>`. Re-copy it from Manage Tokens above."


---

# Claude Code

Stream Claude Code's usage telemetry to OpenObserve with no code changes. The
installer turns on Claude Code's native OpenTelemetry exporter — metrics,
events, and beta traces over OTLP — by writing the config into `settings.json`.
The OpenObserve Data Sources panel renders the stepped setup card from the
frontmatter above.
