de---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: Cursor
  tagline: "Trace Cursor Agent activity: tool calls, file ops, prompt context."
  runtime: CLI agent
  setup_time: ~2 min
  tone: "#6b7280"

# Live detection — "listening for the first span". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). `stream` MUST match the
# stream the install command writes to (the OTel hook default "default").
detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest
  filter: "service_name = 'cursor'"

doc_url: https://openobserve.ai/docs/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command bootstraps the OTel hook and writes the OpenObserve config to `~/.cursor/hooks/otel_config.json`. **Restart Cursor** afterward. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    note: "Already have the hook installed? Add `--skip-bootstrap` to the command."
    code:
      lang: bash
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/cursor/install.sh | bash -s -- \
          --url={url} \
          --org={org} \
          --token="Basic {token}"

  - title: Use Cursor
    description: "Run any prompt in the Cursor IDE as you normally would — the OTel hook ships a trace per request automatically. **Requires the Cursor desktop app.**"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = cursor`. You'll see a span per Cursor request."
    chip: { kind: traces, label: Traces }
    complete_on: detect
---

# Cursor

Trace Cursor Agent activity: tool calls, file ops, prompt context. The OpenObserve
Data Sources panel renders the stepped setup card from the frontmatter above.
