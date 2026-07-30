---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Hugging Face
  logo: logo.svg
  tagline: "Trace Hugging Face Inference API calls: token usage, latency, and model metadata."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The HF Inference Router is OpenAI-compatible,
  # so the OpenInference OpenAI instrumentor sets operation_name='ChatCompletion'
  # and llm_system='openai'.
  filter: "operation_name = 'ChatCompletion'"
  model_label: Llama-3.1-8B-Instruct

doc_url: https://openobserve.ai/docs/integration/ai/providers/huggingface/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Hugging Face token."
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
        HF_TOKEN=hf_your_token_here

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` **before** creating the client pointed at the HF router."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
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
            api_key=os.environ["HF_TOKEN"],
            base_url="https://router.huggingface.co/v1",
        )

  - title: Run Your App & Test
    description: "Make any inference call with a full Hub model ID, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model="meta-llama/Llama-3.1-8B-Instruct",
            messages=[{"role": "user", "content": "Explain distributed tracing in one sentence."}],
            max_tokens=100,
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = ChatCompletion`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_request_parameters_model
      - llm_model_name
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
    - HF_TOKEN

fix_title: "Instrument Before Creating The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the OpenAI client is created
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then create the client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the OpenAI client creation."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — spans set operation_name='ChatCompletion' and llm_system='openai'. Adjust the filter to match."
  - q: "403 / model not found from the router"
    a: "Only models with an active serverless endpoint work, and gated models (e.g. Llama) require accepting the licence on the Hub with a token that has read scope."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Hugging Face

Trace Hugging Face Inference API calls to OpenObserve via OpenTelemetry. The
Data Sources panel renders the stepped setup card from the frontmatter above;
this body is human-readable notes only.
