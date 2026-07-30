---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Cohere
  logo: logo.svg
  tagline: "Trace Cohere chat calls via manual spans: token usage, latency, prompt and response."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Cohere has no dedicated instrumentor, so
  # calls are wrapped in a manual span named 'cohere.chat' (operation_name).
  filter: "operation_name = 'cohere.chat'"
  model_label: command-r-08-2024

doc_url: https://openobserve.ai/docs/integration/ai/providers/cohere/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Cohere key."
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
        COHERE_API_KEY=your-cohere-api-key

  - title: Install & Instrument
    description: "Install the SDK + Cohere client, call `openobserve_init()`, then wrap each Cohere call in a manual span and extract token counts."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk cohere python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        import os
        from opentelemetry import trace
        import cohere

        tracer = trace.get_tracer(__name__)
        co = cohere.Client(api_key=os.environ["COHERE_API_KEY"])

        def chat(message: str, model: str = "command-r-08-2024") -> str:
            with tracer.start_as_current_span("cohere.chat") as span:
                span.set_attribute("llm_model_name", model)
                span.set_attribute("input_value", message)
                response = co.chat(model=model, message=message)
                output = response.text
                span.set_attribute("output_value", output[:200])
                if hasattr(response, "meta") and response.meta and response.meta.tokens:
                    span.set_attribute("llm_token_count_prompt", response.meta.tokens.input_tokens or 0)
                    span.set_attribute("llm_token_count_completion", response.meta.tokens.output_tokens or 0)
                return output

  - title: Run Your App & Test
    description: "Make any chat call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = chat("Explain distributed tracing in one sentence.")
        print(result)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = cohere.chat`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_completion

extras:
  installs:
    - openobserve-telemetry-sdk
    - cohere
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - COHERE_API_KEY

fix_title: "Initialize OpenObserve Before The First Span"
fix_body: "If your app runs but no spans appear, openobserve_init() ran too late. Re-order so it runs before any span is created:"
fix_snippet: |
  # initialize FIRST — before any tracer.start_as_current_span(...)
  from openobserve import openobserve_init
  openobserve_init()

  from opentelemetry import trace
  tracer = trace.get_tracer(__name__)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() above the first tracer.start_as_current_span() call."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name comes from the string passed to start_as_current_span (here 'cohere.chat'). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "Token counts are missing"
    a: "Token counts are read from response.meta.tokens. Confirm your Cohere SDK version returns usage metadata for chat calls."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Cohere

Trace Cohere chat calls to OpenObserve via OpenTelemetry manual spans. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
