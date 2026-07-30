---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Haystack
  logo: logo.svg
  tagline: "Trace Haystack v2 pipeline runs, component executions, and LLM calls with token usage and cost."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # Haystack generator LLM spans store operation_name as OpenAIGenerator.run.
  filter: "operation_name = 'OpenAIGenerator.run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/haystack/
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
        OPENAI_API_KEY=your-openai-key

  - title: Install & Instrument
    description: "Install the SDK + Haystack instrumentor, then call `HaystackInstrumentor().instrument()` **before** importing any Haystack modules. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-haystack haystack-ai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.haystack import HaystackInstrumentor
        from openobserve import openobserve_init

        HaystackInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Run a pipeline, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        from haystack import Pipeline
        from haystack.components.builders import PromptBuilder
        from haystack.components.generators import OpenAIGenerator

        template = "Answer the following question in one sentence: {{ question }}"

        pipeline = Pipeline()
        pipeline.add_component("prompt", PromptBuilder(template=template))
        pipeline.add_component("llm", OpenAIGenerator(model="gpt-4o-mini"))
        pipeline.connect("prompt.prompt", "llm.prompt")

        result = pipeline.run({"prompt": {"question": "What is OpenTelemetry?"}})
        print(result["llm"]["replies"][0])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = OpenAIGenerator.run`. Each pipeline run produces a CHAIN span with a child span per component carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_usage_cost_input

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-haystack
    - haystack-ai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing Haystack"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing haystack
  HaystackInstrumentor().instrument()
  openobserve_init()

  # only then import and use haystack
  from haystack import Pipeline

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move HaystackInstrumentor().instrument() and openobserve_init() above any haystack import."
  - q: "Spans appear but the filter matches nothing"
    a: "The LLM span name depends on the generator component (e.g. OpenAIGenerator.run). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Haystack

Trace Haystack v2 pipeline runs, component executions, and LLM calls to
OpenObserve via OpenTelemetry. The Data Sources panel renders the stepped setup
card from the frontmatter above; this body is human-readable notes only.
