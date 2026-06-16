---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Restate
  tagline: "Trace Restate service invocations: latency, service/handler names, and status."
  runtime: Python 3.10+
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each invocation is wrapped in a manual span
  # named "restate.invoke", which maps to operation_name.
  filter: "operation_name = 'restate.invoke'"

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/restate/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and the Restate ingress URL."
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
        RESTATE_INGRESS_URL=http://localhost:8080

  - title: Install & Instrument
    description: "Install the SDK + restate-sdk, define a service, then wrap each ingress invocation in a manual span. Full details in the docs."
    chip: { kind: editor, label: client.py }
    required: true
    complete_on: copy
    note: "Run the Restate server (Docker) with RESTATE_OBSERVABILITY__TRACING__ENDPOINT pointed at your OpenObserve traces endpoint, register the service, then run the client below."
    code:
      lang: python
      filename: client.py
      text: |
        # pip install openobserve restate-sdk hypercorn opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os
        import requests

        tracer = trace.get_tracer(__name__)
        ingress = os.environ.get("RESTATE_INGRESS_URL", "http://localhost:8080")

        def invoke(service: str, handler: str, payload: str):
            with tracer.start_as_current_span("restate.invoke") as span:
                span.set_attribute("restate.service", service)
                span.set_attribute("restate.handler", handler)
                span.set_attribute("restate.input", payload[:100])
                resp = requests.post(
                    f"{ingress}/{service}/{handler}",
                    json=payload,
                    headers={"Content-Type": "application/json"},
                    timeout=10,
                )
                span.set_attribute("restate.status_code", resp.status_code)
                span.set_attribute("span_status", "OK" if resp.ok else "ERROR")
                return resp.json()

  - title: Run Your App & Test
    description: "Invoke a registered handler, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: client.py
      text: |
        result = invoke("AIService", "answer", "What is distributed tracing?")
        print(result)

        trace.get_tracer_provider().force_flush()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = restate.invoke`. Each invocation span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - restate_service
      - restate_handler
      - restate_status_code

extras:
  installs:
    - openobserve
    - restate-sdk
    - hypercorn
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - RESTATE_INGRESS_URL

fix_title: "Flush Spans Before Exit"
fix_body: "Short-lived scripts can exit before the batch exporter flushes. Force a flush after your last invocation:"
fix_snippet: |
  # initialize FIRST
  openobserve_init()

  # ... run your invocations ...

  # flush before the process exits
  trace.get_tracer_provider().force_flush()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before getting the tracer, and add trace.get_tracer_provider().force_flush() before the script exits."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (here restate.invoke). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "The invocation request fails to connect"
    a: "Make sure the Restate server is running and the service is registered via POST /deployments, and that RESTATE_INGRESS_URL points at the ingress (port 8080)."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Restate

Trace Restate service invocations to OpenObserve via OpenTelemetry. Each HTTP
ingress call is wrapped in a manual span. The Data Sources panel renders the
stepped setup card from the frontmatter above.
