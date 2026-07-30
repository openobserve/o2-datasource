---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Pipecat
  logo: logo.png
  tagline: "Trace Pipecat voice pipeline turns: per-turn LLM spans, token usage, and latency."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each pipeline turn is wrapped in a manual
  # span named "pipecat.llm_service", which maps to operation_name.
  filter: "operation_name = 'pipecat.llm_service'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/pipecat/
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
    description: "Install the SDK + OpenAI instrumentor + Pipecat, then instrument **before** importing Pipecat. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Call OpenAIInstrumentor().instrument() before importing Pipecat so the underlying OpenAI calls are traced as child spans."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai "pipecat-ai[openai]" opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from opentelemetry import trace
        import os
        import asyncio
        from openai import AsyncOpenAI

        tracer = trace.get_tracer(__name__)
        client = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])

        async def pipeline_turn(user_message: str) -> str:
            with tracer.start_as_current_span("pipecat.llm_service") as span:
                span.set_attribute("pipecat.service", "OpenAILLMService")
                span.set_attribute("pipecat.model", "gpt-4o-mini")
                span.set_attribute("pipecat.user_message", user_message[:200])
                response = await client.chat.completions.create(
                    model="gpt-4o-mini",
                    messages=[{"role": "user", "content": user_message}],
                    max_tokens=200,
                )
                reply = response.choices[0].message.content
                span.set_attribute("pipecat.assistant_message", reply[:200])
                span.set_attribute("pipecat.prompt_tokens", response.usage.prompt_tokens)
                span.set_attribute("pipecat.completion_tokens", response.usage.completion_tokens)
                return reply

  - title: Run Your App & Test
    description: "Run a pipeline turn, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        async def main():
            reply = await pipeline_turn("Explain distributed tracing in one sentence.")
            print(reply)

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = pipecat.llm_service`. Each turn is a root span with a child LLM span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - pipecat_service
      - pipecat_prompt_tokens
      - llm_model_name

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - pipecat-ai[openai]
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing Pipecat"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing pipecat / openai usage
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then import and use pipecat
  from opentelemetry import trace

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above any Pipecat or OpenAI usage."
  - q: "Spans appear but the filter matches nothing"
    a: "The root span name is whatever you pass to start_as_current_span (here pipecat.llm_service). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Pipecat

Trace Pipecat voice AI pipeline turns to OpenObserve via OpenTelemetry. Manual
spans wrap each LLM service call, with the OpenAI instrumentor providing child
spans. The Data Sources panel renders the stepped setup card from the frontmatter.
