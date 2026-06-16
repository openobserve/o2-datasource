---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LlamaIndex
  tagline: "Trace LlamaIndex query, retrieve, and LLM spans for every pipeline run with token usage and cost."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The query engine root CHAIN span stores
  # operation_name as BaseQueryEngine.query.
  filter: "operation_name = 'BaseQueryEngine.query'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/llamaindex/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials."
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
        # your model provider key
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + LlamaIndex instrumentor, then call `LlamaIndexInstrumentor().instrument()` **before** importing LlamaIndex components. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly. Pin llama-index-core to 0.10.68 on Python 3.9."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve "openinference-instrumentation-llama-index==2.2.4" "llama-index-core==0.10.68" "llama-index-llms-openai==0.1.31" python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.llama_index import LlamaIndexInstrumentor
        from openobserve import openobserve_init

        LlamaIndexInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Run a query, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import os
        from llama_index.core import VectorStoreIndex, Document, Settings
        from llama_index.llms.openai import OpenAI

        Settings.llm = OpenAI(model="gpt-4o-mini", api_key=os.environ["OPENAI_API_KEY"])

        documents = [
            Document(text="OpenObserve is an observability platform for logs, metrics, and traces."),
            Document(text="OpenTelemetry is a vendor-neutral standard for collecting telemetry data."),
        ]
        index = VectorStoreIndex.from_documents(documents)
        query_engine = index.as_query_engine()

        response = query_engine.query("What is OpenObserve?")
        print(response)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = BaseQueryEngine.query`. Each query produces a root span with retriever and LLM child spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_usage_cost_input

extras:
  installs:
    - openobserve
    - openinference-instrumentation-llama-index
    - llama-index-core
    - llama-index-llms-openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing LlamaIndex"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing llama_index components
  LlamaIndexInstrumentor().instrument()
  openobserve_init()

  # only then import and use llama_index
  from llama_index.core import VectorStoreIndex

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move LlamaIndexInstrumentor().instrument() and openobserve_init() above any llama_index import."
  - q: "SyntaxError or import errors on Python 3.9"
    a: "Pin llama-index-core to 0.10.68 and the instrumentor to 2.2.4. Later versions need Python 3.10+."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# LlamaIndex

Trace LlamaIndex query, retrieve, and LLM spans to OpenObserve via OpenTelemetry.
The Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
