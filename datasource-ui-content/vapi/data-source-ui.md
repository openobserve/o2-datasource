---
# vapi/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Vapi
  tagline: "Trace Vapi voice AI API calls: assistant metadata, request paths, status, and latency."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Calls are wrapped in manual spans named
  # vapi.create_assistant / vapi.api_call; assistant creation maps to operation_name.
  filter: "operation_name = 'vapi.create_assistant'"

doc_url: https://openobserve.ai/docs/integration/ai/no-code/vapi/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Vapi private API key."
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
        VAPI_API_KEY=your-vapi-private-api-key

  - title: Install & Wrap The API Calls
    description: "Install the SDK, init OpenObserve with a service name, then wrap each Vapi REST call in a manual span. Vapi uses an `Authorization: Bearer` header (not x-api-key)."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init, openobserve_shutdown
        openobserve_init(resource_attributes={"service.name": "my-app"})

        from opentelemetry import trace
        import os, requests

        tracer = trace.get_tracer(__name__)
        VAPI_BASE = "https://api.vapi.ai"
        headers = {
            "Authorization": f"Bearer {os.environ['VAPI_API_KEY']}",
            "Content-Type": "application/json",
        }

        def create_assistant(name: str, first_message: str):
            with tracer.start_as_current_span("vapi.create_assistant") as span:
                span.set_attribute("vapi.assistant_name", name)
                resp = requests.post(f"{VAPI_BASE}/assistant", headers=headers, json={
                    "name": name,
                    "firstMessage": first_message,
                    "model": {"provider": "openai", "model": "gpt-4o-mini"},
                    "voice": {"provider": "11labs", "voiceId": "paula"},
                })
                resp.raise_for_status()
                assistant_id = resp.json()["id"]
                span.set_attribute("vapi.assistant_id", assistant_id)
                return assistant_id

  - title: Run It & Test
    description: "Create an assistant, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        assistant_id = create_assistant("ObsBot", "Hello! How can I assist you?")
        print(assistant_id)

        openobserve_shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = vapi.create_assistant`. Each API call produces a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - vapi_assistant_id
      - vapi_status_code
      - span_status

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-api
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Init Before The First API Call & Flush At The End"
fix_body: "If your app runs but no spans appear, init too late or never flushed. Init first and shut down before exit:"
fix_snippet: |
  # init FIRST, before any Vapi call
  openobserve_init(resource_attributes={"service.name": "my-app"})
  tracer = trace.get_tracer(__name__)

  # ... wrap calls in tracer.start_as_current_span(...) ...

  # flush + export before the process exits
  openobserve_shutdown()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before any Vapi call and openobserve_shutdown() before the process exits so spans are flushed."
  - q: "Vapi returns 401"
    a: "Use the private API key from the Vapi dashboard with the Authorization: Bearer header. Vapi does not accept x-api-key."
  - q: "Spans appear under the wrong service"
    a: "service.name comes from openobserve_init(resource_attributes=...). Filter by operation_name = vapi.create_assistant if the service name differs."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Vapi

Trace Vapi voice AI API calls to OpenObserve via OpenTelemetry by wrapping the
Vapi REST API in manual spans. The Data Sources panel renders the stepped setup
card from the frontmatter above; this body is human-readable notes only.
