---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: OpenAI Codex
  tagline: Per-conversation logs from every Codex CLI session.
  runtime: CLI agent
  setup_time: ~2 min
  tone: "#10a37f"

# Live detection — "listening for the first log record". The card polls a cheap
# COUNT over this stream/filter (windowed to listen-time). Codex emits LOGS (not
# traces) in exec mode, so stream_type is logs and we match service_name.
detect:
  stream_type: logs
  stream: default
  # best-effort; confirm on ingest
  filter: "service_name = 'codex_exec'"

doc_url: https://openobserve.ai/docs/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command points Codex at OpenObserve — writes an `[otel.exporter.otlp-http]` block into `~/.codex/config.toml`. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/codex/install.sh | bash -s -- \
          --url={url} \
          --org={org} \
          --token="Basic {token}"

  - title: Use Codex
    description: "Run any Codex command — each session streams a log record to OpenObserve:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: bash
      text: |
        codex exec "say hi"

  - title: Check OpenObserve
    description: "Open **Logs** and filter `service_name = codex_exec`. You'll see a log record per session."
    chip: { kind: logs, label: Logs }
    complete_on: detect
    pills:
      - service_name
---

# OpenAI Codex

Per-conversation logs from every Codex CLI session. The OpenObserve Data Sources
panel renders the stepped setup card from the frontmatter above.
