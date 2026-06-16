---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: DSPy
  tagline: "Trace DSPy module executions, LLM calls, and optimiser runs with token usage."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. DSPy module CHAIN spans store operation_name
  # as Module.forward (e.g. Predict(QA).forward); filter on the forward suffix.
  filter: "operation_name LIKE '%forward%'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/dspy/
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
    description: "Install the SDK + DSPy instrumentor, then call `DSPyInstrumentor().instrument()` **before** importing DSPy. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk "openinference-instrumentation-dspy==0.1.16" "dspy==2.6.13" python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.dspy import DSPyInstrumentor
        from openobserve import openobserve_init

        DSPyInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Run a DSPy module, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import os
        import dspy

        lm = dspy.LM("openai/gpt-4o-mini", api_key=os.environ["OPENAI_API_KEY"])
        dspy.configure(lm=lm)

        class QA(dspy.Signature):
            """Answer questions with short factual answers."""
            question: str = dspy.InputField()
            answer: str = dspy.OutputField()

        predict = dspy.Predict(QA)
        result = predict(question="What is OpenTelemetry?")
        print(result.answer)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name` containing `forward`. Each module call produces a CHAIN span with a child LLM span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - openinference_span_kind
      - llm_usage_tokens_input
      - llm_usage_tokens_output

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-dspy
    - dspy
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing DSPy"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing dspy
  DSPyInstrumentor().instrument()
  openobserve_init()

  # only then import and use dspy
  import dspy

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move DSPyInstrumentor().instrument() and openobserve_init() above any dspy import."
  - q: "Spans appear but the filter matches nothing"
    a: "Module span names depend on the module class (e.g. Predict(QA).forward). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# DSPy

Trace DSPy module executions, LLM calls, and optimiser runs to OpenObserve via
OpenTelemetry. The Data Sources panel renders the stepped setup card from the
frontmatter above; this body is human-readable notes only.
