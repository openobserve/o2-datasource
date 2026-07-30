---
# portkey/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Portkey
  logo: logo.png
  tagline: "Trace every request routed through the Portkey gateway: model, token usage, and latency."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Portkey is OpenAI-compatible, so the OpenAI
  # instrumentor emits ChatCompletion spans with llm_system='openai'.
  filter: "operation_name = 'ChatCompletion'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/gateways/portkey/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Portkey + provider keys."
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
        PORTKEY_API_KEY=your-portkey-api-key
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then instrument **before** creating the client. Point the client at the Portkey endpoint with the routing headers."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        import os
        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["PORTKEY_API_KEY"],
            base_url="https://api.portkey.ai/v1",
            default_headers={
                "x-portkey-api-key": os.environ["PORTKEY_API_KEY"],
                "x-portkey-provider": "openai",
                "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}",
            },
        )

  - title: Run It & Test
    description: "Make any call through the gateway, then click **Test** to detect the first span:"
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
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = ChatCompletion`. Each routed call produces an `LLM` span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_total

extras:
  installs:
    - openobserve-telemetry-sdk
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

  # only then create the Portkey-pointed client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the line that creates the OpenAI client."
  - q: "Portkey returns 401 / provider error"
    a: "Pass x-portkey-api-key plus either x-portkey-provider + an Authorization Bearer provider key, or an x-portkey-virtual-key for a configured virtual key."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and read the actual operation_name; for non-chat endpoints it may differ. Adjust the filter to match."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Portkey

Trace requests routed through the Portkey AI gateway to OpenObserve via
OpenTelemetry. Portkey exposes an OpenAI-compatible API, so the standard OpenAI
instrumentor captures spans when pointed at the Portkey endpoint. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
