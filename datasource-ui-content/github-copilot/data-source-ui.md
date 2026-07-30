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

# Live detection — Copilot's exporter appends /v1/traces to the base endpoint,
# so spans land in the default traces stream. OTEL_SERVICE_NAME (set in step 1)
# stamps service_name = 'github-copilot' on every signal.
detect:
  stream_type: traces
  stream: default
  # confirmed in docs: with OTEL_SERVICE_NAME=github-copilot every span carries it
  filter: "service_name = 'github-copilot'"

doc_url: https://openobserve.ai/docs/integration/ai/github-copilot-tracing/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Configure The Copilot CLI
    description: "Export the OTLP variables before starting `copilot` (add to your shell profile to persist). All of the first three are required: without `COPILOT_OTEL_EXPORTER_TYPE` the CLI writes to a local file instead of OTLP, and without `http/protobuf` OpenObserve rejects the payload. The endpoint is the **base** URL with no trailing slash — the exporter appends `/v1/traces` itself."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      text: |
        export COPILOT_OTEL_ENABLED=true
        export COPILOT_OTEL_EXPORTER_TYPE=otlp-http
        export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
        export OTEL_EXPORTER_OTLP_ENDPOINT="{url}/api/{org}"
        export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic {token}"
        export OTEL_SERVICE_NAME=github-copilot

  - title: Using VS Code Instead? Configure Copilot Chat
    description: "For the Copilot Chat extension, enable OTel in `settings.json`. The auth header can't be set there — launch VS Code from a shell that has `OTEL_EXPORTER_OTLP_HEADERS` exported (step 1)."
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
    description: "Run a Copilot session — `copilot` in a terminal, or Copilot Chat in VS Code — and ask it anything. Every agent turn exports automatically: model calls, tool executions, token usage."
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

fix_title: "Restart The Session With The Variables Set"
fix_body: "The exporter reads its config at session start. If nothing arrives, confirm the variables are set in the shell that launched Copilot (or VS Code), check the CLI's own log, then start a fresh session:"
fix_lang: bash
fix_snippet: |
  # confirm the exporter config is visible to the session
  env | grep -E 'COPILOT_OTEL|OTEL_EXPORTER'

  # the CLI logs its OTel state — startup line must say exporter=otlp-http
  grep -i "OpenTelemetry enabled" ~/.copilot/logs/$(ls -t ~/.copilot/logs/ | head -1)

  # endpoint must be the BASE url with no trailing slash: .../api/{org}
  # then start a new copilot session (or relaunch VS Code from this shell)

troubleshooting:
  - q: "Sessions run but no data appears"
    a: "Set COPILOT_OTEL_ENABLED=true and start a fresh session — the exporter config is read at session start, not mid-session."
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
