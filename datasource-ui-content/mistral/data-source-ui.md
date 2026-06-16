---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Mistral
  tagline: "Trace Mistral AI inference calls: token usage, latency, and model metadata."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenInference Mistral instrumentor sets
  # operation_name='MistralClient.chat' and llm_system='mistralai'.
  filter: "operation_name = 'MistralClient.chat'"
  model_label: mistral-small-latest

doc_url: https://openobserve.ai/docs/integration/ai/providers/mistral/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Mistral key."
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
        MISTRAL_API_KEY=your-mistral-api-key

  - title: Install & Instrument
    description: "Install the SDK + Mistral instrumentor, then call `MistralAIInstrumentor().instrument()` **before** importing the Mistral client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk "openinference-instrumentation-mistralai==1.4.0" mistralai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.mistralai import MistralAIInstrumentor
        from openobserve import openobserve_init

        MistralAIInstrumentor().instrument()
        openobserve_init()

        import os
        from mistralai import Mistral

        client = Mistral(api_key=os.environ["MISTRAL_API_KEY"])

  - title: Run Your App & Test
    description: "Make any chat call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.complete(
            model="mistral-small-latest",
            messages=[{"role": "user", "content": "Explain observability in one sentence."}],
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = MistralClient.chat`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_usage_tokens_input
      - llm_usage_tokens_output

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-mistralai
    - mistralai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - MISTRAL_API_KEY

fix_title: "Instrument Before Importing The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the Mistral client is imported
  MistralAIInstrumentor().instrument()
  openobserve_init()

  # only then import and use the client
  from mistralai import Mistral

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move MistralAIInstrumentor().instrument() and openobserve_init() above the `from mistralai import Mistral` line."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — Mistral spans set operation_name='MistralClient.chat'. Adjust the filter to match."
  - q: "ImportError or instrumentor mismatch"
    a: "Pin the instrumentor to a version compatible with your mistralai SDK (the docs use openinference-instrumentation-mistralai==1.4.0)."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Mistral

Trace Mistral AI inference calls to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
