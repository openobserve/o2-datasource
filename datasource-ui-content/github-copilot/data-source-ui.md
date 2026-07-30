---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# GitHub Copilot (CLI + VS Code Copilot Chat) ships a native OpenTelemetry
# exporter — point it at OpenObserve's OTLP endpoint. No collector, no SDK,
# no code changes.
card:
  name: GitHub Copilot
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: Stream Copilot agent traces, metrics, and events to OpenObserve — no code changes.
  runtime: CLI agent
  setup_time: ~2 min

# Live detection — Copilot's exporter appends /v1/traces to the base endpoint;
# the installer adds a stream-name header so spans land in the stream chosen
# below. OTEL_SERVICE_NAME (written by the installer) stamps
# service_name = 'github-copilot' on every signal.
detect:
  stream_type: traces
  stream: default                # fallback; overridden by the stream_input value below
  # verified on ingest: with OTEL_SERVICE_NAME=github-copilot every span carries it
  filter: "service_name = 'github-copilot'"

# Renders a "Stream Name" text field. Its value feeds the install command's
# {stream} placeholder AND the detection stream above, so what the installer
# writes and what the card listens on can never drift.
stream_input:
  label: Stream Name
  default: default
  placeholder: default
  help: 'Traces stream for Copilot spans. Leave as "default" or set a dedicated stream.'

doc_url: https://openobserve.ai/docs/integration/ai/github-copilot-tracing/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command persists Copilot's OpenTelemetry env config into your shell profile — every new terminal (and any VS Code launched from one) exports automatically. It sets the two variables GitHub's docs miss: `COPILOT_OTEL_EXPORTER_TYPE=otlp-http` (the CLI otherwise writes to a local file) and `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` (OTLP JSON is rejected). Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/github-copilot/install.sh | bash -s -- \
          --url={url} \
          --org={org} \
          --stream={stream} \
          --token="Basic {token}"

  - title: Using VS Code Instead? Configure Copilot Chat
    description: "For the Copilot Chat extension, enable OTel in `settings.json`. The auth header can't be set there — it comes from the env block the installer wrote in step 1, so launch VS Code from a **new** terminal (`code .`)."
    chip: { kind: editor, label: settings.json }
    complete_on: copy
    note: "Skip this step if you only use the Copilot CLI."
    code:
      lang: json
      filename: settings.json
      text: |
        {
          "github.copilot.chat.otel.enabled": true,
          "github.copilot.chat.otel.exporterType": "otlp-http",
          "github.copilot.chat.otel.otlpEndpoint": "{url}/api/{org}"
        }

  - title: Use Copilot
    description: "Open a **new** terminal (so the installer's env block loads) and run a Copilot session — `copilot`, or Copilot Chat in VS Code launched from that terminal — and ask it anything. Every agent turn exports automatically: model calls, tool executions, token usage."
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = github-copilot`. Each turn is an `invoke_agent` root span with `chat` and `execute_tool` children. Events land in **Logs**; token-usage and duration histograms in **Metrics**."
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_operation_name
      - gen_ai_request_model
      - gen_ai_usage_input_tokens
      - gen_ai_usage_output_tokens
      - gen_ai_tool_name

extras:
  env_vars:
    - COPILOT_OTEL_ENABLED
    - COPILOT_OTEL_EXPORTER_TYPE
    - OTEL_EXPORTER_OTLP_PROTOCOL
    - OTEL_EXPORTER_OTLP_ENDPOINT
    - OTEL_EXPORTER_OTLP_HEADERS
    - OTEL_SERVICE_NAME

fix_title: "Open A New Terminal And Start A Fresh Session"
fix_body: "The exporter reads its config at session start, from the shell's env. If nothing arrives, confirm the installer's block is loaded in the shell that launched Copilot, check the CLI's own log, then start a fresh session:"
fix_lang: bash
fix_snippet: |
  # confirm the installer's env block is loaded in THIS shell
  env | grep -E 'COPILOT_OTEL|OTEL_EXPORTER'

  # the CLI logs its OTel state — startup line must say exporter=otlp-http
  grep -i "OpenTelemetry enabled" ~/.copilot/logs/$(ls -t ~/.copilot/logs/ | head -1)

  # if the env is missing, re-run the installer (safe to re-run), then
  # open a NEW terminal and start a new copilot session

troubleshooting:
  - q: "Sessions run but no data appears"
    a: "The env block loads at shell start and the exporter reads it at session start. Open a new terminal, confirm with `env | grep COPILOT_OTEL`, and run a fresh `copilot` session — sessions already running keep their old env."
  - q: "The CLI log says `exporter=file`"
    a: "The CLI defaults to a local file exporter. Set COPILOT_OTEL_EXPORTER_TYPE=otlp-http and start a fresh session."
  - q: "The CLI log says `HTTP export failed: network error`"
    a: "That's OpenObserve rejecting OTLP JSON with a 400. Set OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf — the payload then ingests cleanly."

---

# GitHub Copilot

Stream GitHub Copilot's native OpenTelemetry export — agent traces, metrics,
and events from the Copilot CLI and VS Code Copilot Chat — to OpenObserve with
no code changes. The Data Sources panel renders the stepped setup card from the
frontmatter above; this body is human-readable notes only.
