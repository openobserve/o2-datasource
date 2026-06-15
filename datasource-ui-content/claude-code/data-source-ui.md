---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: Claude Code
  tagline: Trace every Claude Code conversation turn, no code changes.
  runtime: CLI agent
  setup_time: ~2 min
  tone: "#d97757"

# Live detection — "listening for the first span". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). `stream` MUST match the
# stream the install command writes to (the OTel config the installer writes into
# Claude Code's settings.json ships to the default traces stream).
detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest
  filter: "service_name = 'claude-code'"

doc_url: https://openobserve.ai/docs/integration/ai/claude-code-tracing/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command registers a `Stop` hook and writes the OpenObserve OTel config into Claude Code's `settings.json`. Safe to re-run."
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
    description: "Just use Claude Code normally — start a session and run a turn in any project. The `Stop` hook ships a trace automatically each turn."
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service.name = claude-code`. You'll see a span tree per turn:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - service.name
      - tool calls
      - model usage

---

# Claude Code

Trace every Claude Code conversation turn, no code changes. The OpenObserve Data
Sources panel renders the stepped setup card from the frontmatter above.
