---
# posthog/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: PostHog
  tagline: "Trace LLM generations in OpenObserve while capturing $ai_generation events in PostHog."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each generation is wrapped in a manual span
  # named posthog.llm_generation, which OpenObserve maps to operation_name.
  filter: "operation_name = 'posthog.llm_generation'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/posthog/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials, OpenAI key, and PostHog project key + host."
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
        POSTHOG_API_KEY=phc_your_project_api_key
        POSTHOG_HOST=https://app.posthog.com

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor + PostHog client, then instrument **before** creating any clients. Each generation is captured in both systems."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai posthog openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from opentelemetry import trace
        import os, uuid, posthog
        from openai import OpenAI

        tracer = trace.get_tracer(__name__)
        posthog.api_key = os.environ["POSTHOG_API_KEY"]
        posthog.host = os.environ.get("POSTHOG_HOST", "https://app.posthog.com")
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
        def generate(prompt: str, user_id: str = None) -> str:
            with tracer.start_as_current_span("posthog.llm_generation") as span:
                span.set_attribute("posthog.model", "gpt-4o-mini")
                span.set_attribute("posthog.prompt", prompt[:200])
                response = client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=[{"role": "user", "content": prompt}],
                    max_tokens=200,
                )
                reply = response.choices[0].message.content
                trace_id = hex(span.get_span_context().trace_id)
                posthog.capture(user_id or str(uuid.uuid4()), "$ai_generation", {
                    "$ai_provider": "openai",
                    "$ai_model": "gpt-4o-mini",
                    "$ai_input_tokens": response.usage.prompt_tokens,
                    "$ai_output_tokens": response.usage.completion_tokens,
                    "$ai_trace_id": trace_id,
                })
                return reply

        print(generate("Explain distributed tracing in one sentence.", user_id="user-123"))
        posthog.shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = posthog.llm_generation`. Each call produces a span (with an OpenAI child span) carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - posthog_model
      - llm_token_count_prompt
      - llm_token_count_completion

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - posthog
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

  # only then configure PostHog and create the OpenAI client
  posthog.api_key = ...
  client = OpenAI(api_key=...)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the lines that configure PostHog and create the OpenAI client."
  - q: "Events reach PostHog but no trace in OpenObserve"
    a: "Confirm openobserve_init() ran and the manual posthog.llm_generation span wraps the call. Cross-reference with the $ai_trace_id property."
  - q: "PostHog events not appearing"
    a: "Check POSTHOG_API_KEY (phc_…) and POSTHOG_HOST, and call posthog.shutdown() before exit to flush the queue."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# PostHog

Capture $ai_generation events in PostHog for product analytics while exporting
full OTel traces to OpenObserve, linked by $ai_trace_id. The Data Sources panel
renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
