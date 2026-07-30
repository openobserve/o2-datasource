---
# vercel-ai-gateway/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Vercel AI Gateway
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace every LLM call routed through the Vercel AI Gateway: model, tokens, routing, and cost."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. openobserve_init sets service.name to
  # vercel-ai-gateway, and the OpenAI instrumentor emits ChatCompletion spans.
  filter: "service_name = 'vercel-ai-gateway'"
  model_label: anthropic/claude-haiku-4.5

doc_url: https://openobserve.ai/docs/integration/ai/gateways/vercel-ai-gateway/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Vercel AI Gateway API key (`vck_…`)."
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
        VERCEL_AI_GATEWAY_API_KEY=vck_...

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then follow the import order exactly: load env, instrument, init OpenObserve, then create the gateway-pointed client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() must run first — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openai openinference-instrumentation-openai openobserve-telemetry-sdk python-dotenv
        import os
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        OpenAIInstrumentor().instrument()

        from openobserve import openobserve_init, openobserve_shutdown
        openobserve_init(resource_attributes={"service.name": "vercel-ai-gateway"})

        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["VERCEL_AI_GATEWAY_API_KEY"],
            base_url="https://ai-gateway.vercel.sh/v1",
        )

  - title: Run It & Test
    description: "Make any call (models use `provider/model-id` format), then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model="anthropic/claude-haiku-4.5",
            messages=[{"role": "user", "content": "What is distributed tracing?"}],
            max_tokens=100,
        )
        print(response.choices[0].message.content)

        openobserve_shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = vercel-ai-gateway`. Each `ChatCompletion` span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_total
      - output_value

extras:
  installs:
    - openai
    - openinference-instrumentation-openai
    - openobserve-telemetry-sdk
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Follow The Import Order"
fix_body: "If your app runs but no spans appear, the instrumentor loaded too late. Instrument before importing the OpenAI client:"
fix_snippet: |
  # instrument FIRST — before importing the OpenAI client
  OpenAIInstrumentor().instrument()
  openobserve_init(resource_attributes={"service.name": "vercel-ai-gateway"})

  # only then import and create the gateway-pointed client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Keep the exact order: load_dotenv() -> OpenAIInstrumentor().instrument() -> openobserve_init() -> import OpenAI. Also call openobserve_shutdown() before exit to flush."
  - q: "Gateway returns 401"
    a: "VERCEL_AI_GATEWAY_API_KEY must be a vck_ key with credit. Filter span_status = ERROR in Traces to inspect auth/rate-limit failures."
  - q: "Model not found"
    a: "The gateway expects provider/model-id format, e.g. anthropic/claude-haiku-4.5 or openai/gpt-4o-mini."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Vercel AI Gateway

Trace LLM calls routed through the Vercel AI Gateway to OpenObserve via
OpenTelemetry. The gateway is OpenAI-compatible, so the standard OpenAI
instrumentor captures spans — including gateway routing and cost metadata in
output_value. The Data Sources panel renders the stepped setup card from the
frontmatter above; this body is human-readable notes only.
