---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Promptfoo
  logo: logo.png
  tagline: "Trace Promptfoo eval cases: prompt, pass/fail, and token usage with nested LLM spans."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each eval case is wrapped in a manual span
  # named promptfoo.eval_case, which OpenObserve maps to operation_name.
  filter: "operation_name = 'promptfoo.eval_case'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/promptfoo/
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
    description: "Install the SDK + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` and `openobserve_init()` **before** running evaluations. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai openai opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from opentelemetry import trace
        import os
        from openai import OpenAI

        tracer = trace.get_tracer(__name__)
        client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

  - title: Run It & Test
    description: "Run the eval cases, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        eval_cases = [
            {"prompt": "What is distributed tracing?", "expected_keyword": "trace"},
            {"prompt": "What is a span?", "expected_keyword": "span"},
        ]

        for case in eval_cases:
            with tracer.start_as_current_span("promptfoo.eval_case") as span:
                span.set_attribute("promptfoo.prompt", case["prompt"])
                span.set_attribute("promptfoo.expected_keyword", case["expected_keyword"])
                response = client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=[{"role": "user", "content": case["prompt"]}],
                    max_tokens=100,
                )
                output = response.choices[0].message.content
                passed = case["expected_keyword"].lower() in output.lower()
                span.set_attribute("promptfoo.output", output[:300])
                span.set_attribute("promptfoo.pass", passed)
                span.set_attribute("promptfoo.prompt_tokens", response.usage.prompt_tokens)
                span.set_attribute("promptfoo.completion_tokens", response.usage.completion_tokens)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = promptfoo.eval_case`. Each case produces a root span with a child LLM span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - promptfoo_prompt
      - promptfoo_pass
      - promptfoo_completion_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - openai
    - opentelemetry-api
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Running Evals"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing the openai client
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then import and run eval cases inside manual spans
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above any openai import, and wrap each eval case in a manual span."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (e.g. promptfoo.eval_case). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Promptfoo

Trace Promptfoo LLM evaluation cases to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
