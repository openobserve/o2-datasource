---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LiveKit
  tagline: "Trace LiveKit Agents LLM calls with latency, token usage, input messages, and output content."
  runtime: Python 3.10+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # The instrumentation wraps each LLM call in a manual span named
  # livekit.llm_call, stored as operation_name.
  filter: "operation_name = 'livekit.llm_call'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/livekit/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root. LiveKit exports via raw OTLP env vars."
    chip: { kind: editor, label: .env }
    complete_on: copy
    code:
      lang: bash
      filename: .env
      download_env: true
      text: |
        OPENAI_API_KEY=your-openai-api-key
        OTEL_EXPORTER_OTLP_ENDPOINT={url}/api/{org}/v1/traces
        OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic {token}

  - title: Install & Instrument
    description: "Install LiveKit Agents + the OTLP exporter, build a `TracerProvider`, and pass it to `telemetry.set_tracer_provider()` **before** making any LLM calls. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Set the tracer provider before importing/using the LiveKit LLM so the SDK attaches its spans as children."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install "livekit-agents[openai]" opentelemetry-exporter-otlp-proto-http opentelemetry-sdk python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        import os
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.resources import Resource
        from opentelemetry import trace as trace_api

        auth_header = os.environ["OTEL_EXPORTER_OTLP_HEADERS"].replace("Authorization=", "")
        provider = TracerProvider(resource=Resource.create({"service.name": "my-app"}))
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(
            endpoint=os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"],
            headers={"Authorization": auth_header},
        )))
        trace_api.set_tracer_provider(provider)

        from livekit.agents import telemetry, llm
        from livekit.plugins import openai as lk_openai
        telemetry.set_tracer_provider(provider)

  - title: Run Your App & Test
    description: "Make an LLM call inside a manual span, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import asyncio

        tracer = trace_api.get_tracer(__name__)
        model = lk_openai.LLM(model="gpt-4o-mini")

        async def main():
            with tracer.start_as_current_span("livekit.llm_call") as span:
                span.set_attribute("livekit.question", "What is distributed tracing?")
                ctx = llm.ChatContext()
                ctx.add_message(role="user", content="What is distributed tracing?")
                collected = await model.chat(chat_ctx=ctx).collect()
                span.set_attribute("livekit.answer_preview", (collected.text or "")[:80])
                span.set_attribute("span_status", "OK")
                print(collected.text)
            provider.force_flush()

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = livekit.llm_call`. Each call produces a manual root span with nested `llm_request` spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - livekit_input_tokens
      - livekit_output_tokens
      - gen_ai_request_model

extras:
  installs:
    - livekit-agents
    - opentelemetry-exporter-otlp-proto-http
    - opentelemetry-sdk
    - python-dotenv
  env_vars:
    - OTEL_EXPORTER_OTLP_ENDPOINT
    - OTEL_EXPORTER_OTLP_HEADERS
    - OPENAI_API_KEY

fix_title: "Set the Tracer Provider Before LLM Calls"
fix_body: "If your app runs but no spans appear, the provider was registered too late or never flushed. Set it first and flush before exit:"
fix_snippet: |
  # set the provider BEFORE any LLM call
  trace_api.set_tracer_provider(provider)
  telemetry.set_tracer_provider(provider)

  # ... make calls ...
  provider.force_flush()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Register the TracerProvider with both trace_api.set_tracer_provider() and telemetry.set_tracer_provider() before any LLM call, and call provider.force_flush() before the process exits."
  - q: "401/403 from the OTLP endpoint"
    a: "OTEL_EXPORTER_OTLP_HEADERS must be Authorization=Basic <base64>. Re-copy the token from Manage Tokens."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Wrong endpoint path"
    a: "OTEL_EXPORTER_OTLP_ENDPOINT must end in /api/<org>/v1/traces for traces ingestion."

---

# LiveKit

Trace LiveKit Agents LLM calls to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
