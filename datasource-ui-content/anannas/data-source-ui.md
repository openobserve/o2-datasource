---
# anannas/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Anannas
  tagline: "Trace every Anannas gateway call: model, token usage, and latency across 500+ models."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. openobserve_init(service_name="anannas") sets
  # the resource service name, and the OpenAI instrumentor emits ChatCompletion spans.
  filter: "service_name = 'anannas'"
  model_label: claude-haiku-4.5

doc_url: https://openobserve.ai/docs/integration/ai/gateways/anannas/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Anannas + provider keys."
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
        ANANNAS_API_KEY=your-anannas-api-key
        ANTHROPIC_API_KEY=your-anthropic-api-key

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then instrument **before** creating the client. Point the client at the Anannas base URL."
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
        openobserve_init(service_name="anannas")

        import os
        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["ANANNAS_API_KEY"],
            base_url="https://anannas.ai/v1",
            default_headers={"x-provider-api-key": os.environ["ANTHROPIC_API_KEY"]},
        )

  - title: Run It & Test
    description: "Make any inference call through the gateway, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model="claude-haiku-4.5",
            messages=[{"role": "user", "content": "Explain distributed tracing in one sentence."}],
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = anannas`. Each gateway call produces an `LLM` span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_token_count_completion

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
  openobserve_init(service_name="anannas")

  # only then create the Anannas-pointed client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the line that creates the OpenAI client."
  - q: "Spans appear but the filter matches nothing"
    a: "Confirm you passed service_name='anannas' to openobserve_init(). Open Traces, read the actual service_name, and adjust the filter."
  - q: "Gateway returns 401 / provider error"
    a: "Anannas needs both ANANNAS_API_KEY (as api_key) and your provider key forwarded via the x-provider-api-key header."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Anannas

Trace Anannas LLM gateway calls to OpenObserve via OpenTelemetry. Anannas is an
OpenAI-compatible gateway to 500+ models, instrumented with the standard OpenAI
instrumentor pointed at the Anannas base URL. The Data Sources panel renders the
stepped setup card from the frontmatter above; this body is human-readable notes only.
