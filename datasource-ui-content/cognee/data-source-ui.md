---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Cognee
  tagline: "Trace Cognee knowledge graph ingest, cognify, and search operations."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Manual spans are named cognee.search /
  # cognee.ingest, which OpenObserve maps to operation_name.
  filter: "operation_name = 'cognee.search'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/cognee/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and OpenAI key."
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
        # used by Cognee for embeddings and LLM reasoning
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + Cognee, call `openobserve_init()` **before** Cognee, then wrap each pipeline stage in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk cognee opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os
        import asyncio
        import cognee
        from cognee import SearchType

        tracer = trace.get_tracer(__name__)

        cognee.config.set_llm_config({
            "llm_provider": "openai",
            "llm_model": "gpt-4o-mini",
            "llm_api_key": os.environ["OPENAI_API_KEY"],
        })

  - title: Run It & Test
    description: "Run an ingest + search, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        async def main():
            with tracer.start_as_current_span("cognee.ingest") as span:
                await cognee.prune.prune_data()
                await cognee.add([
                    "OpenObserve is an observability platform for logs, metrics, and traces.",
                ])
                await cognee.cognify()
                span.set_attribute("cognee.document_count", 1)

            with tracer.start_as_current_span("cognee.search") as span:
                query = "What is OpenObserve?"
                span.set_attribute("cognee.query", query)
                results = await cognee.search(SearchType.SUMMARIES, query)
                span.set_attribute("cognee.result_count", len(results))

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = cognee.search`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - cognee_query
      - cognee_result_count
      - cognee_document_count

extras:
  installs:
    - openobserve-telemetry-sdk
    - cognee
    - opentelemetry-api
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Calling Cognee"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before calling cognee
  from openobserve import openobserve_init
  openobserve_init()

  # only then use cognee inside manual spans
  import cognee

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() above any cognee call, and ensure each operation is wrapped in tracer.start_as_current_span()."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. cognee.search). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Cognee

Trace Cognee knowledge graph ingest, cognify, and search operations to
OpenObserve via OpenTelemetry. The Data Sources panel renders the stepped setup
card from the frontmatter above; this body is human-readable notes only.
