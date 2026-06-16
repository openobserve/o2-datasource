---
# trubrics/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Trubrics
  tagline: "Trace LLM generations in OpenObserve while recording user feedback in Trubrics."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each generation is wrapped in a manual span
  # named trubrics.llm_with_feedback, which OpenObserve maps to operation_name.
  filter: "operation_name = 'trubrics.llm_with_feedback'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/trubrics/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials, OpenAI key, and Trubrics API key."
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
        TRUBRICS_API_KEY=your-trubrics-api-key

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor + Trubrics client, then instrument **before** creating any clients. Each generation is recorded with feedback in both systems."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai trubrics openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from opentelemetry import trace
        import os, uuid
        from trubrics import Trubrics
        from openai import OpenAI

        tracer = trace.get_tracer(__name__)
        tb = Trubrics(api_key=os.environ["TRUBRICS_API_KEY"])
        client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

  - title: Run It & Test
    description: "Make a tracked generation, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        def generate_and_collect_feedback(prompt: str, user_id: str = None) -> str:
            with tracer.start_as_current_span("trubrics.llm_with_feedback") as span:
                span.set_attribute("trubrics.prompt", prompt[:200])
                span.set_attribute("trubrics.model", "gpt-4o-mini")
                response = client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=[{"role": "user", "content": prompt}],
                    max_tokens=200,
                )
                reply = response.choices[0].message.content
                trace_id = hex(span.get_span_context().trace_id)
                span.set_attribute("trubrics.trace_id", trace_id)
                tb.track(
                    user_id=user_id or str(uuid.uuid4()),
                    prompt=prompt,
                    generation=reply,
                    tags={"model": "gpt-4o-mini", "trace_id": trace_id},
                )
                return reply

        print(generate_and_collect_feedback(
            "Explain distributed tracing in one sentence.", user_id="user-123",
        ))

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = trubrics.llm_with_feedback`. Each call produces a span (with an OpenAI child span) carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - trubrics_model
      - llm_token_count_prompt
      - llm_token_count_completion

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - trubrics
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Creating The Clients"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before any client is created
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then create the OpenAI + Trubrics clients
  client = OpenAI(api_key=...)
  tb = Trubrics(api_key=...)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the lines that create the OpenAI and Trubrics clients."
  - q: "Feedback reaches Trubrics but no trace in OpenObserve"
    a: "Confirm openobserve_init() ran and the manual trubrics.llm_with_feedback span wraps the call. Cross-reference via the trace_id tag."
  - q: "Trubrics events not appearing"
    a: "Check TRUBRICS_API_KEY is valid and let the process finish so tb.track() flushes."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Trubrics

Record user feedback in Trubrics while exporting full OTel generation traces to
OpenObserve, linked by trace_id. The Data Sources panel renders the stepped setup
card from the frontmatter above; this body is human-readable notes only.
