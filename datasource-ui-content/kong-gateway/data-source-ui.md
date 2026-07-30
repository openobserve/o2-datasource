---
# kong-gateway/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Kong AI Gateway
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace every request proxied through Kong: model, token usage, cost, and proxy overhead."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Kong is a transparent OpenAI-compatible proxy,
  # so the OpenAI instrumentor emits ChatCompletion spans with llm_system='openai'.
  filter: "operation_name = 'ChatCompletion'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/gateways/kong-gateway/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials, OpenAI key, and the Kong proxy URL."
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
        KONG_GATEWAY_URL=http://localhost:8000/openai/v1

  - title: Start Kong & Instrument
    description: "Start Kong in DB-less mode with a declarative config that proxies to OpenAI, then instrument **before** creating the client and point it at the Kong proxy."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Run Kong first (docker run … kong:latest with KONG_DECLARATIVE_CONFIG=kong.yml routing /openai → https://api.openai.com), then run the Python app."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve openinference-instrumentation-openai openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        import os
        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["OPENAI_API_KEY"],
            base_url=os.environ.get("KONG_GATEWAY_URL", "http://localhost:8000/openai/v1"),
        )

  - title: Run It & Test
    description: "Make any call through the Kong proxy, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": "Explain distributed tracing in one sentence."}],
            max_tokens=20,
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = ChatCompletion`. Each proxied call produces an `LLM` span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_total
      - duration

extras:
  installs:
    - openobserve
    - openinference-instrumentation-openai
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Creating The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the OpenAI client is created
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then create the Kong-pointed client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the line that creates the OpenAI client."
  - q: "Connection refused to the Kong proxy"
    a: "Confirm Kong is running (docker ps) and KONG_GATEWAY_URL points at the proxy port (default 8000) plus the /openai/v1 route path."
  - q: "Kong returns 404 for the route"
    a: "Check kong.yml — the service URL must be https://api.openai.com and the route path /openai with strip_path: true. Restart the container after editing."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Kong AI Gateway

Trace requests proxied through Kong AI Gateway to OpenObserve via OpenTelemetry.
Kong is a transparent OpenAI-compatible proxy, so the standard OpenAI instrumentor
captures spans with no gateway-specific code. The Data Sources panel renders the
stepped setup card from the frontmatter above; this body is human-readable notes only.
