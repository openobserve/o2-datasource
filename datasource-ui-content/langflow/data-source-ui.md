---
# langflow/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Langflow
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace Langflow flow executions: flow ID, inputs, output length, and latency."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each flow run is wrapped in a manual span
  # named langflow.run_flow, which OpenObserve maps to operation_name.
  filter: "operation_name = 'langflow.run_flow'"

doc_url: https://openobserve.ai/docs/integration/ai/no-code/langflow/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Langflow base URL, flow ID, and API key."
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
        LANGFLOW_BASE_URL=http://localhost:7860
        LANGFLOW_FLOW_ID=your-flow-id
        LANGFLOW_API_KEY=your-langflow-api-key

  - title: Install & Wrap The Flow Call
    description: "Install the SDK, init OpenObserve, then wrap each Langflow run call in a manual span. Find the flow ID in the Langflow UI URL; create an API key under Settings > API Keys."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-sdk python-dotenv requests
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os, requests, uuid

        tracer = trace.get_tracer(__name__)
        base_url = os.environ["LANGFLOW_BASE_URL"]
        flow_id = os.environ["LANGFLOW_FLOW_ID"]
        api_key = os.environ.get("LANGFLOW_API_KEY", "")

        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["x-api-key"] = api_key

  - title: Run It & Test
    description: "Run a flow, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        with tracer.start_as_current_span("langflow.run_flow") as span:
            span.set_attribute("langflow.flow_id", flow_id)
            span.set_attribute("langflow.input", "Explain distributed tracing in one sentence.")
            resp = requests.post(
                f"{base_url}/api/v1/run/{flow_id}",
                headers=headers,
                json={
                    "input_value": "Explain distributed tracing in one sentence.",
                    "output_type": "chat",
                    "input_type": "chat",
                    "session_id": str(uuid.uuid4()),
                },
                timeout=30,
            )
            resp.raise_for_status()
            output = str(resp.json().get("outputs", ""))
            span.set_attribute("langflow.output_length", len(output))
            span.set_attribute("span_status", "OK")
            print(output[:200])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = langflow.run_flow`. Each run produces a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - langflow_flow_id
      - langflow_output_length
      - span_status

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-sdk
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Init Before The First Flow Call"
fix_body: "If your app runs but no spans appear, init loaded too late. Call init first, then wrap the flow call:"
fix_snippet: |
  # init FIRST, before any flow call
  openobserve_init()
  tracer = trace.get_tracer(__name__)

  # only then wrap the run
  with tracer.start_as_current_span("langflow.run_flow") as span:
      ...

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before the first flow call. Short scripts may exit before the exporter flushes — let the SDK shut down cleanly."
  - q: "401 / 403 from Langflow"
    a: "Create an API key under Settings > API Keys and pass it via the x-api-key header (LANGFLOW_API_KEY)."
  - q: "404 from the run endpoint"
    a: "LANGFLOW_FLOW_ID must be the UUID from the flow's browser URL, and LANGFLOW_BASE_URL must reach the running instance (default port 7860)."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Langflow

Trace Langflow flow executions to OpenObserve via OpenTelemetry by wrapping the
Langflow run API in manual spans. The Data Sources panel renders the stepped
setup card from the frontmatter above; this body is human-readable notes only.
