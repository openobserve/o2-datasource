---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Exa
  tagline: "Trace Exa semantic search calls: query text, result counts, and latency."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Manual spans are named exa.search, which
  # OpenObserve maps to operation_name.
  filter: "operation_name = 'exa.search'"

doc_url: https://openobserve.ai/docs/integration/ai/tools/exa/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Exa key."
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
        EXA_API_KEY=your-exa-api-key

  - title: Install & Instrument
    description: "Install the SDK + exa-py, call `openobserve_init()` **before** importing Exa, then wrap each search in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk exa-py opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os
        from exa_py import Exa

        tracer = trace.get_tracer(__name__)
        client = Exa(api_key=os.environ["EXA_API_KEY"])

        def search(query: str, num_results: int = 5):
            with tracer.start_as_current_span("exa.search") as span:
                span.set_attribute("exa.query", query)
                span.set_attribute("exa.num_results", num_results)
                result = client.search(query, num_results=num_results)
                span.set_attribute("exa.result_count", len(result.results))
                return result

  - title: Run It & Test
    description: "Make a search call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = search("OpenTelemetry distributed tracing")
        for r in result.results:
            print(r.title, r.url)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = exa.search`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - exa_query
      - exa_num_results
      - exa_result_count

extras:
  installs:
    - openobserve-telemetry-sdk
    - exa-py
    - opentelemetry-api
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Importing Exa"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before importing exa
  from openobserve import openobserve_init
  openobserve_init()

  # only then import and use exa inside manual spans
  from exa_py import Exa

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() above any exa_py import, and ensure each search is wrapped in tracer.start_as_current_span()."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. exa.search). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Exa

Trace Exa semantic search calls to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
