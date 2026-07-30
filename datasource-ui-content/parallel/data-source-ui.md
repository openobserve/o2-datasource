---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Parallel
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace Parallel AI task runs: run ID, processor tier, status, and latency."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each task submission is wrapped in a manual
  # span named parallel.run_task, which OpenObserve maps to operation_name.
  filter: "operation_name = 'parallel.run_task'"

doc_url: https://openobserve.ai/docs/integration/ai/tools/parallel/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Parallel key."
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
        PARALLEL_API_KEY=your-parallel-api-key

  - title: Install & Instrument
    description: "Install the SDK + requests, call `openobserve_init()` first, then wrap each task submission in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init(resource_attributes={"service.name": "my-app"})

        from opentelemetry import trace
        import os
        import requests

        tracer = trace.get_tracer(__name__)

        BASE_URL = "https://api.parallel.ai/v1"
        headers = {"x-api-key": os.environ["PARALLEL_API_KEY"], "Content-Type": "application/json"}

        def run_task(task: str, processor: str = "core"):
            with tracer.start_as_current_span("parallel.run_task") as span:
                span.set_attribute("parallel.task", task[:100])
                span.set_attribute("parallel.processor", processor)
                resp = requests.post(
                    f"{BASE_URL}/tasks/runs",
                    headers=headers,
                    json={"input": task, "processor": processor},
                    timeout=30,
                )
                resp.raise_for_status()
                data = resp.json()
                span.set_attribute("parallel.run_id", data.get("run_id", ""))
                span.set_attribute("parallel.status", data.get("status", ""))
                return data

  - title: Run It & Test
    description: "Submit one task, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = run_task("Explain distributed tracing in one sentence.")
        print(result)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = parallel.run_task`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - parallel_run_id
      - parallel_processor
      - parallel_status

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

fix_title: "Initialize Before Submitting Tasks"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before any task submission
  from openobserve import openobserve_init
  openobserve_init(resource_attributes={"service.name": "my-app"})

  # only then submit tasks inside manual spans
  import requests

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() to the top, and ensure each submission is wrapped in tracer.start_as_current_span()."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. parallel.run_task). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "API returns 401 / 403"
    a: "Check PARALLEL_API_KEY is set and sent as the x-api-key header."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Parallel

Trace Parallel AI task submissions to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
