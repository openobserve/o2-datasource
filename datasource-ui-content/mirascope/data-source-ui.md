---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Mirascope
  tagline: "Trace Mirascope LLM calls: token usage, latency, and model metadata."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Mirascope has no OTel instrumentor; you wrap
  # calls in a manual span named "mirascope.call", which maps to operation_name.
  filter: "operation_name = 'mirascope.call'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/mirascope/
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
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + Mirascope, call `openobserve_init()`, then wrap each call in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk mirascope python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        from mirascope.openai import OpenAICall, OpenAICallParams

        tracer = trace.get_tracer(__name__)

        class Answer(OpenAICall):
            prompt_template = "Answer in one sentence: {question}"
            call_params = OpenAICallParams(model="gpt-4o-mini", max_tokens=100)
            question: str

        def traced_answer(question: str) -> str:
            with tracer.start_as_current_span("mirascope.call") as span:
                span.set_attribute("llm_model_name", "gpt-4o-mini")
                span.set_attribute("input_value", question)
                response = Answer(question=question).call()
                output = response.content
                span.set_attribute("output_value", output[:200])
                if response.usage:
                    span.set_attribute("llm_token_count_prompt", response.usage.prompt_tokens or 0)
                    span.set_attribute("llm_token_count_completion", response.usage.completion_tokens or 0)
                return output

  - title: Run Your App & Test
    description: "Make any Mirascope call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        print(traced_answer("What is OpenTelemetry?"))

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = mirascope.call`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_completion

extras:
  installs:
    - openobserve-telemetry-sdk
    - mirascope
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Wrapping Calls"
fix_body: "If your app runs but no spans appear, the tracer provider wasn't set up first. Re-order so init runs before the call:"
fix_snippet: |
  # initialize FIRST — registers the tracer provider
  openobserve_init()

  # only then get the tracer and wrap your Mirascope call
  tracer = trace.get_tracer(__name__)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before creating the tracer or wrapping any Mirascope call."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (here mirascope.call). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Mirascope

Trace Mirascope LLM calls to OpenObserve via OpenTelemetry. Mirascope has no
dedicated instrumentor, so calls are wrapped in manual spans. The Data Sources
panel renders the stepped setup card from the frontmatter above.
