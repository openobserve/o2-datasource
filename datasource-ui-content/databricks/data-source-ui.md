---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Databricks
  tagline: "Trace Databricks Model Serving calls: token usage, latency, and resolved model metadata."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Model Serving is OpenAI-compatible, so the
  # OpenInference OpenAI instrumentor sets operation_name='ChatCompletion' and
  # llm_system='openai'.
  filter: "operation_name = 'ChatCompletion'"
  model_label: databricks-llama-4-maverick

doc_url: https://openobserve.ai/docs/integration/ai/providers/databricks/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Databricks settings."
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
        DATABRICKS_HOST=https://adb-1234567890123456.7.azuredatabricks.net
        DATABRICKS_TOKEN=dapiXXXXXXXXXXXXXXXXXXXXXXXXXXXX
        DATABRICKS_MODEL=databricks-llama-4-maverick

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` **before** creating the client pointed at your workspace serving endpoint."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init
        from opentelemetry import trace

        OpenAIInstrumentor().instrument()
        openobserve_init()

        import os
        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["DATABRICKS_TOKEN"],
            base_url=f"{os.environ['DATABRICKS_HOST'].rstrip('/')}/serving-endpoints",
        )

  - title: Run Your App & Test
    description: "Make any serving-endpoint call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model=os.environ.get("DATABRICKS_MODEL", "databricks-llama-4-maverick"),
            messages=[{"role": "user", "content": "Explain distributed tracing in one sentence."}],
            max_tokens=100,
        )
        print(response.choices[0].message.content)
        trace.get_tracer_provider().force_flush()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = ChatCompletion`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_request_parameters_model
      - llm_token_count_total

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - DATABRICKS_TOKEN

fix_title: "Instrument Before Creating The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the OpenAI client is created
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then create the client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the OpenAI client creation, and keep the force_flush() call before exit."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — spans set operation_name='ChatCompletion' and llm_system='openai'. Adjust the filter to match."
  - q: "401 / 403 from the serving endpoint"
    a: "Confirm DATABRICKS_TOKEN has model-serving permissions and DATABRICKS_HOST points at your workspace URL."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Databricks

Trace Databricks Model Serving calls to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
