---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Groq
  tagline: "Trace Groq inference calls: token usage, latency, and model metadata."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenInference Groq instrumentor sets
  # operation_name='Completions' and openinference_span_kind='LLM'.
  filter: "operation_name = 'Completions'"
  model_label: llama-3.1-8b-instant

doc_url: https://openobserve.ai/docs/integration/ai/providers/groq/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Groq key."
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
        GROQ_API_KEY=your-groq-api-key

  - title: Install & Instrument
    description: "Install the SDK + Groq instrumentor, then call `GroqInstrumentor().instrument()` **before** importing the Groq client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-groq groq python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.groq import GroqInstrumentor
        from openobserve import openobserve_init

        GroqInstrumentor().instrument()
        openobserve_init()

        import os
        from groq import Groq

        client = Groq(api_key=os.environ["GROQ_API_KEY"])

  - title: Run Your App & Test
    description: "Make any inference call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model="llama-3.1-8b-instant",
            messages=[{"role": "user", "content": "Explain observability in one sentence."}],
        )
        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = Completions`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_usage_tokens_input
      - llm_usage_tokens_output

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-groq
    - groq
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - GROQ_API_KEY

fix_title: "Instrument Before Importing The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the Groq client is imported
  GroqInstrumentor().instrument()
  openobserve_init()

  # only then import and use the client
  from groq import Groq

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move GroqInstrumentor().instrument() and openobserve_init() above the `from groq import Groq` line."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — Groq spans set operation_name='Completions'. Adjust the filter to match."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Groq

Trace Groq inference calls to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
