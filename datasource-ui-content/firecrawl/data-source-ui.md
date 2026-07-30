---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Firecrawl
  logo: logo.svg
  tagline: "Trace Firecrawl scrape and crawl calls: target URL, content length, and latency."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Manual spans are named firecrawl.scrape,
  # which OpenObserve maps to operation_name.
  filter: "operation_name = 'firecrawl.scrape'"

doc_url: https://openobserve.ai/docs/integration/ai/tools/firecrawl/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Firecrawl key."
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
        FIRECRAWL_API_KEY=your-firecrawl-api-key

  - title: Install & Instrument
    description: "Install the SDK + firecrawl-py, call `openobserve_init()` **before** importing Firecrawl, then wrap each scrape in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk firecrawl-py opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os
        from firecrawl import FirecrawlApp

        tracer = trace.get_tracer(__name__)
        app = FirecrawlApp(api_key=os.environ["FIRECRAWL_API_KEY"])

        def scrape(url: str):
            with tracer.start_as_current_span("firecrawl.scrape") as span:
                span.set_attribute("firecrawl.url", url)
                result = app.scrape_url(url, formats=["markdown"])
                span.set_attribute("firecrawl.content_length", len(result.get("markdown", "")))
                return result

  - title: Run It & Test
    description: "Scrape a page, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = scrape("https://openobserve.ai")
        print(result.get("markdown", "")[:500])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = firecrawl.scrape`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - firecrawl_url
      - firecrawl_content_length
      - duration

extras:
  installs:
    - openobserve-telemetry-sdk
    - firecrawl-py
    - opentelemetry-api
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Importing Firecrawl"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before importing firecrawl
  from openobserve import openobserve_init
  openobserve_init()

  # only then import and use firecrawl inside manual spans
  from firecrawl import FirecrawlApp

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() above any firecrawl import, and ensure each scrape is wrapped in tracer.start_as_current_span()."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. firecrawl.scrape). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Firecrawl

Trace Firecrawl scrape and crawl calls to OpenObserve via OpenTelemetry. The
Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
