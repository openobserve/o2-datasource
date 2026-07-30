---
# flowise/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Flowise
  logo: logo.png
  tagline: "Trace Flowise chatflow predictions: chatflow ID, question, response length, and latency."
  runtime: Python 3.8+
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each prediction call is wrapped in a manual
  # span named flowise.chatflow_predict, which OpenObserve maps to operation_name.
  filter: "operation_name = 'flowise.chatflow_predict'"

doc_url: https://openobserve.ai/docs/integration/ai/no-code/flowise/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Flowise base URL + chatflow ID."
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
        FLOWISE_BASE_URL=http://localhost:3000
        FLOWISE_CHATFLOW_ID=your_chatflow_id

  - title: Start Flowise & Wrap The Prediction
    description: "Run Flowise via Docker (it can also export native OTLP traces), build a chatflow, then init OpenObserve and wrap each prediction call in a manual span."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Optional native OTLP: pass -e OTEL_EXPORTER_OTLP_ENDPOINT=<url>/api/<org>/v1/traces and -e \"OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <token>\" to the flowiseai/flowise container."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve opentelemetry-sdk opentelemetry-exporter-otlp python-dotenv requests
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os, requests

        tracer = trace.get_tracer(__name__)
        base_url = os.environ["FLOWISE_BASE_URL"]
        chatflow_id = os.environ["FLOWISE_CHATFLOW_ID"]

  - title: Run It & Test
    description: "Send a prediction to your chatflow, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        with tracer.start_as_current_span("flowise.chatflow_predict") as span:
            span.set_attribute("flowise_chatflow_id", chatflow_id)
            span.set_attribute("flowise_question", "Explain distributed tracing in one sentence.")
            resp = requests.post(
                f"{base_url}/api/v1/prediction/{chatflow_id}",
                headers={"Content-Type": "application/json"},
                json={"question": "Explain distributed tracing in one sentence."},
                timeout=30,
            )
            resp.raise_for_status()
            text = resp.json().get("text", "")
            span.set_attribute("flowise_answer_length", len(text))
            span.set_attribute("span_status", "OK")
            print(text)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = flowise.chatflow_predict`. Each prediction produces a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - flowise_chatflow_id
      - flowise_answer_length
      - span_status

extras:
  installs:
    - openobserve
    - opentelemetry-sdk
    - opentelemetry-exporter-otlp
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Init Before The First Prediction"
fix_body: "If your app runs but no spans appear, init loaded too late. Call init first, then wrap the prediction call:"
fix_snippet: |
  # init FIRST, before any prediction call
  openobserve_init()
  tracer = trace.get_tracer(__name__)

  # only then wrap the prediction
  with tracer.start_as_current_span("flowise.chatflow_predict") as span:
      ...

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before the first prediction. Short scripts may exit before the exporter flushes — add a brief sleep or let the SDK shut down cleanly."
  - q: "404 from the prediction endpoint"
    a: "FLOWISE_CHATFLOW_ID must be the UUID from the chatflow canvas URL, and FLOWISE_BASE_URL must reach the running Flowise instance."
  - q: "Flowise container not exporting native traces"
    a: "Confirm the OTEL_EXPORTER_OTLP_ENDPOINT ends in /api/<org>/v1/traces and the OTEL_EXPORTER_OTLP_HEADERS auth value is correct, then restart the container."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Flowise

Trace Flowise chatflow predictions to OpenObserve via OpenTelemetry. Flowise is
an open-source drag-and-drop LLM flow builder; this integration wraps prediction
API calls in manual spans (and Flowise can also export native OTLP traces). The
Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
