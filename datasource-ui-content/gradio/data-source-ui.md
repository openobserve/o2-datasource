---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Gradio
  logo: logo.svg
  tagline: "Trace Gradio chat and prediction calls with nested LLM spans."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The prediction function is wrapped in a
  # manual span named gradio.chat_predict, which OpenObserve maps to operation_name.
  filter: "operation_name = 'gradio.chat_predict'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/gradio/
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
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + Gradio + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` and `openobserve_init()` **before** defining the Gradio interface. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai "gradio==4.20.0" "huggingface_hub<1.0" openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from opentelemetry import trace
        import os
        import gradio as gr
        from openai import OpenAI

        tracer = trace.get_tracer(__name__)
        client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

  - title: Run It & Test
    description: "Launch the interface and send one chat message, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        def chat(message: str, history: list) -> str:
            with tracer.start_as_current_span("gradio.chat_predict") as span:
                span.set_attribute("gradio.input_length", len(message))
                span.set_attribute("gradio.history_turns", len(history))
                messages = [{"role": "user", "content": message}]
                response = client.chat.completions.create(
                    model="gpt-4o-mini", messages=messages, max_tokens=200,
                )
                reply = response.choices[0].message.content
                span.set_attribute("gradio.output_length", len(reply))
                return reply

        gr.ChatInterface(chat).launch()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = gradio.chat_predict`. Each chat turn produces a root span with a child LLM span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gradio_input_length
      - gradio_output_length
      - llm_model_name

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - gradio
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Defining The Interface"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing gradio / openai
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then import and define the gradio interface
  import gradio as gr

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above any gradio or openai import, and ensure the prediction body is wrapped in a manual span."
  - q: "Spans appear but the filter matches nothing"
    a: "The root span name is whatever you pass to start_as_current_span (e.g. gradio.chat_predict). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Gradio

Trace Gradio chat and prediction calls to OpenObserve via OpenTelemetry. The
Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
