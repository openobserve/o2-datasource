---
# n8n/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: n8n
  logo: logo.svg
  tagline: "Trace n8n webhook triggers: webhook path, payload keys, status code, and latency."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each webhook trigger is wrapped in a manual
  # span named n8n.webhook_trigger, which OpenObserve maps to operation_name.
  filter: "operation_name = 'n8n.webhook_trigger'"

doc_url: https://openobserve.ai/docs/integration/ai/no-code/n8n/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your n8n base URL + webhook path."
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
        N8N_BASE_URL=http://localhost:5678
        N8N_WEBHOOK_ID=your-webhook-path

  - title: Install & Wrap The Trigger
    description: "Install the SDK, init OpenObserve, then wrap each webhook trigger in a manual span. n8n can also export native workflow traces via OTLP env vars (see note)."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Optional native OTLP: start n8n with -e N8N_METRICS=true, -e OTEL_EXPORTER_OTLP_ENDPOINT=<url>/api/<org>/v1/traces and -e \"OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <token>\"."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os, requests

        tracer = trace.get_tracer(__name__)
        base_url = os.environ.get("N8N_BASE_URL", "http://localhost:5678")
        webhook_id = os.environ["N8N_WEBHOOK_ID"]

        def trigger_webhook(payload: dict):
            with tracer.start_as_current_span("n8n.webhook_trigger") as span:
                span.set_attribute("n8n.webhook_id", webhook_id)
                span.set_attribute("n8n.payload_keys", str(list(payload.keys())))
                resp = requests.post(
                    f"{base_url}/webhook/{webhook_id}",
                    headers={"Content-Type": "application/json"},
                    json=payload, timeout=30,
                )
                span.set_attribute("n8n.status_code", resp.status_code)
                span.set_attribute("span_status", "OK" if resp.ok else "ERROR")
                return resp

  - title: Run It & Test
    description: "Trigger your webhook, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = trigger_webhook({"message": "Explain distributed tracing."})
        print(result.status_code, result.text)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = n8n.webhook_trigger`. Each trigger produces a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - n8n_webhook_id
      - n8n_status_code
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

fix_title: "Init Before The First Trigger"
fix_body: "If your app runs but no spans appear, init loaded too late. Call init first, then wrap the trigger:"
fix_snippet: |
  # init FIRST, before any webhook trigger
  openobserve_init()
  tracer = trace.get_tracer(__name__)

  # only then wrap the trigger
  def trigger_webhook(payload):
      with tracer.start_as_current_span("n8n.webhook_trigger") as span:
          ...

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before the first trigger. Short scripts may exit before the exporter flushes — let the SDK shut down cleanly."
  - q: "404 from the webhook"
    a: "N8N_WEBHOOK_ID must match the webhook path of an active workflow, and the workflow must be activated (not just saved) in n8n."
  - q: "Native n8n traces not arriving"
    a: "Confirm the OTEL_EXPORTER_OTLP_ENDPOINT ends in /api/<org>/v1/traces and the auth header is correct, then restart the n8n container."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# n8n

Trace n8n webhook triggers to OpenObserve via OpenTelemetry by wrapping webhook
calls in manual spans (n8n can also export native workflow traces via OTLP env
vars). The Data Sources panel renders the stepped setup card from the frontmatter
above; this body is human-readable notes only.
