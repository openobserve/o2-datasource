---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Zapier
  tagline: "Trace Zapier webhook triggers: payload metadata, status codes, and latency."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each webhook call is wrapped in a manual
  # span named zapier.webhook_trigger, which OpenObserve maps to operation_name.
  filter: "operation_name = 'zapier.webhook_trigger'"

doc_url: https://openobserve.ai/docs/integration/ai/tools/zapier/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "In Zapier, create a Zap with **Webhooks by Zapier** (Catch Hook) as the trigger and copy the webhook URL. Then create a `.env` with your OpenObserve credentials and that URL."
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
        ZAPIER_WEBHOOK_URL=https://hooks.zapier.com/hooks/catch/<your_hook_id>/

  - title: Install & Instrument
    description: "Install the SDK + requests, call `openobserve_init()` first, then wrap each webhook POST in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os
        import requests

        tracer = trace.get_tracer(__name__)
        webhook_url = os.environ["ZAPIER_WEBHOOK_URL"]

        def trigger_zap(topic: str, question: str):
            with tracer.start_as_current_span("zapier.webhook_trigger") as span:
                span.set_attribute("zapier.topic", topic)
                span.set_attribute("zapier.question", question[:100])
                resp = requests.post(webhook_url, json={"topic": topic, "question": question}, timeout=15)
                span.set_attribute("zapier.status_code", resp.status_code)
                span.set_attribute("span_status", "OK" if resp.ok else "ERROR")
                return resp.json()

  - title: Run It & Test
    description: "Fire one webhook, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = trigger_zap("observability", "What is distributed tracing?")
        print(result)

        trace.get_tracer_provider().force_flush()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = zapier.webhook_trigger`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - zapier_topic
      - zapier_question
      - zapier_status_code

extras:
  installs:
    - openobserve
    - opentelemetry-api
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Triggering Webhooks"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before any webhook call
  from openobserve import openobserve_init
  openobserve_init()

  # only then trigger webhooks inside manual spans, then force_flush()
  import requests

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() to the top, wrap each POST in a manual span, and call force_flush() before the script exits."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. zapier.webhook_trigger). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "Webhook returns a non-200 status"
    a: "Confirm ZAPIER_WEBHOOK_URL is the Catch Hook URL from your Zap and that the Zap is turned on."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Zapier

Trace Zapier webhook triggers to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
