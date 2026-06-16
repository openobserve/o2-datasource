---
# mixpanel/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Mixpanel
  tagline: "Trace LLM calls in OpenObserve while recording usage events in Mixpanel, linked by trace_id."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each LLM call is wrapped in a manual span
  # named mixpanel.llm_call, which OpenObserve maps to operation_name.
  filter: "operation_name = 'mixpanel.llm_call'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/mixpanel/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials, OpenAI key, and Mixpanel project token."
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
        MIXPANEL_TOKEN=your-mixpanel-project-token

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor + Mixpanel client, then instrument **before** creating any clients. Each LLM call is tracked in both systems."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai mixpanel openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from opentelemetry import trace
        import os, uuid, mixpanel
        from openai import OpenAI

        tracer = trace.get_tracer(__name__)
        mp = mixpanel.Mixpanel(os.environ["MIXPANEL_TOKEN"])
        client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

  - title: Run It & Test
    description: "Make a tracked LLM call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        def generate(prompt: str, user_id: str = None) -> str:
            with tracer.start_as_current_span("mixpanel.llm_call") as span:
                span.set_attribute("mixpanel.model", "gpt-4o-mini")
                span.set_attribute("mixpanel.prompt", prompt[:200])
                response = client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=[{"role": "user", "content": prompt}],
                    max_tokens=200,
                )
                reply = response.choices[0].message.content
                trace_id = hex(span.get_span_context().trace_id)
                mp.track(user_id or str(uuid.uuid4()), "LLM Call", {
                    "model": "gpt-4o-mini",
                    "prompt_tokens": response.usage.prompt_tokens,
                    "completion_tokens": response.usage.completion_tokens,
                    "trace_id": trace_id,
                })
                return reply

        print(generate("Explain distributed tracing in one sentence.", user_id="user-123"))

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = mixpanel.llm_call`. Each call produces a span (with an OpenAI child span) carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - mixpanel_model
      - llm_token_count_prompt
      - llm_token_count_completion

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - mixpanel
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

  # only then create the OpenAI + Mixpanel clients
  client = OpenAI(api_key=...)
  mp = mixpanel.Mixpanel(...)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the lines that create the OpenAI and Mixpanel clients."
  - q: "Events reach Mixpanel but no trace in OpenObserve"
    a: "Confirm openobserve_init() ran and the manual mixpanel.llm_call span wraps the call. Use the trace_id property to cross-reference."
  - q: "Mixpanel events not appearing"
    a: "Check MIXPANEL_TOKEN is the project token; mp.track() may buffer — let the process finish cleanly."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Mixpanel

Record LLM usage events in Mixpanel for product analytics while exporting full
OTel traces to OpenObserve, linked by trace_id. The Data Sources panel renders
the stepped setup card from the frontmatter above; this body is human-readable
notes only.
