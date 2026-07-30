---
# lobechat/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LobeChat
  logo: logo.svg
  tagline: "Trace every LobeChat chat request: route, HTTP status, and end-to-end latency."
  runtime: Docker
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. LobeChat exports HTTP server spans with
  # OTEL_SERVICE_NAME=lobechat, stored as service_name on ingest.
  filter: "service_name = 'lobechat'"

doc_url: https://openobserve.ai/docs/integration/ai/no-code/lobechat/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Configure OTLP Export
    description: "LobeChat has built-in OpenTelemetry support. Set these OTLP env vars so traces export straight to OpenObserve. The exporter appends `/v1/traces` automatically, so omit the path suffix."
    chip: { kind: editor, label: .env }
    complete_on: copy
    code:
      lang: bash
      filename: .env
      download_env: true
      text: |
        OPENOBSERVE_URL={url}
        OPENOBSERVE_ORG={org}
        OPENOBSERVE_AUTH_TOKEN=Basic {token}
        ENABLE_TELEMETRY=1
        OTEL_EXPORTER_OTLP_ENDPOINT={url}/api/{org}
        OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic {token}
        OTEL_SERVICE_NAME=lobechat

  - title: Run The Container
    description: "Pull the image and start LobeChat with telemetry enabled and the OTLP vars pointed at OpenObserve. `OPENAI_MODEL_LIST` restricts models so requests do not fail silently."
    chip: { kind: terminal, label: Terminal }
    required: true
    complete_on: copy
    note: "From inside Docker, use host.docker.internal (or your OpenObserve host) in the endpoint instead of localhost."
    code:
      lang: bash
      filename: run-lobechat.sh
      text: |
        docker pull lobehub/lobe-chat:latest

        docker run -d --name lobechat \
          -p 3210:3210 \
          -e OPENAI_API_KEY=your_openai_api_key \
          -e OPENAI_MODEL_LIST=gpt-4o-mini \
          -e ENABLE_TELEMETRY=1 \
          -e OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" \
          -e "OTEL_EXPORTER_OTLP_HEADERS=$OTEL_EXPORTER_OTLP_HEADERS" \
          -e OTEL_SERVICE_NAME=lobechat \
          lobehub/lobe-chat:latest

  - title: Send A Chat & Test
    description: "Open LobeChat, select a model, and send a message. Then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: bash
      text: |
        # 1. open http://localhost:3210
        # 2. pick a model from OPENAI_MODEL_LIST
        # 3. send any chat message — it hits /webapi/chat/openai
        open http://localhost:3210

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = lobechat`. Each chat request produces a server span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - http_target
      - http_status_code
      - duration

extras:
  installs:
    - lobehub/lobe-chat (Docker image)
  env_vars:
    - ENABLE_TELEMETRY
    - OTEL_EXPORTER_OTLP_ENDPOINT
    - OTEL_EXPORTER_OTLP_HEADERS
    - OTEL_SERVICE_NAME

fix_title: "Fix The OTLP Endpoint & Headers"
fix_body: "If LobeChat runs but no spans appear, the OTLP target or auth header is wrong. Set the endpoint without the /v1/traces suffix and restart:"
fix_lang: bash
fix_snippet: |
  # endpoint WITHOUT the /v1/traces suffix — the exporter appends it
  OTEL_EXPORTER_OTLP_ENDPOINT=https://api.openobserve.ai/api/your_org_id
  OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <your_base64_token>
  ENABLE_TELEMETRY=1
  # then: docker rm -f lobechat && docker run ... (re-run with the new vars)

troubleshooting:
  - q: "LobeChat runs but no spans appear"
    a: "Confirm ENABLE_TELEMETRY=1 is set and OTEL_EXPORTER_OTLP_ENDPOINT ends at /api/<org> (no /v1/traces). Recreate the container after changing env vars."
  - q: "All chat requests fail and emit no spans"
    a: "Set OPENAI_MODEL_LIST to a model your account can access; otherwise LobeChat defaults to one that errors before a span is recorded."
  - q: "Spans never reach OpenObserve from Docker"
    a: "Replace localhost with host.docker.internal (or the real host) in the endpoint so the container can reach OpenObserve."
  - q: "Auth errors in the OpenObserve logs"
    a: "The OTEL_EXPORTER_OTLP_HEADERS value must be `Authorization=Basic <base64>`. Re-copy the token from Manage Tokens."

---

# LobeChat

Trace LobeChat chat requests to OpenObserve via its built-in OpenTelemetry
support — pass OTLP env vars at startup and HTTP server spans flow directly to
OpenObserve. The Data Sources panel renders the stepped setup card from the
frontmatter above; this body is human-readable notes only.
