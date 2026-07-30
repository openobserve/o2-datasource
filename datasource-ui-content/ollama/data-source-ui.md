---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Ollama
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace local Ollama inference calls: token usage, latency, and model metadata — no cloud key."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenTelemetry Ollama instrumentor sets
  # gen_ai_system='ollama' and gen_ai_request_model on each span.
  filter: "LOWER(gen_ai_system) = 'ollama'"
  model_label: llama3.2

doc_url: https://openobserve.ai/docs/integration/ai/providers/ollama/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Ollama host."
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
        OLLAMA_HOST=http://localhost:11434

  - title: Install & Instrument
    description: "Pull a model, install the SDK + Ollama instrumentor, then call `OllamaInstrumentor().instrument()` **before** any Ollama client is created."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Run `ollama pull llama3.2` first. Instrument before importing the Ollama client so the patch applies."
    code:
      lang: python
      filename: main.py
      text: |
        # ollama pull llama3.2
        # pip install openobserve-telemetry-sdk opentelemetry-instrumentation-ollama ollama python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from opentelemetry.instrumentation.ollama import OllamaInstrumentor
        from openobserve import openobserve_init

        # Instrument before importing the Ollama client
        OllamaInstrumentor().instrument()
        openobserve_init()

        import ollama

  - title: Run Your App & Test
    description: "Make any local inference call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = ollama.chat(
            model="llama3.2",
            messages=[{"role": "user", "content": "Explain distributed tracing in one sentence."}],
        )
        print(response["message"]["content"])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `gen_ai_system = ollama`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_request_model
      - gen_ai_usage_input_tokens
      - gen_ai_usage_output_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-instrumentation-ollama
    - ollama
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - OLLAMA_HOST

fix_title: "Instrument Before Importing Ollama"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before importing ollama
  OllamaInstrumentor().instrument()
  openobserve_init()

  # only then import and use ollama
  import ollama

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OllamaInstrumentor().instrument() and openobserve_init() above the `import ollama` line."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — Ollama spans set gen_ai_system='ollama'. If you use the OpenAI-compatible endpoint instead, instrument with OpenAIInstrumentor and filter on operation_name='ChatCompletion'."
  - q: "Connection refused to Ollama"
    a: "Confirm Ollama is running (`ollama serve`) and OLLAMA_HOST points at the right host/port (default http://localhost:11434)."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Ollama

Trace local Ollama inference calls to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
