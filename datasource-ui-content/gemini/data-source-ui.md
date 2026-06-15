---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: Google Gemini
  tagline: Trace every Gemini API call from your Python app.
  runtime: Python 3.10–3.13
  setup_time: ~2 min
  tone: "#4285f4"

# Live detection — "listening for the first span". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). `stream` MUST match the
# stream the install command writes to (today the SDK default "default").
detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest
  filter: "gen_ai_provider_name = 'gcp.gen_ai'"
  model_label: gemini-2.0-flash

doc_url: https://openobserve.ai/docs/integration/ai/providers/google-gemini/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command installs the SDK + Gemini instrumentor and writes your `.env`. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      download_env: true
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
          --integration=gemini \
          --url={url} \
          --org={org} \
          --token="Basic {token}"

  - title: Add These Lines To Your App
    description: "Required — the installer sets up packages, but spans only flow once your app is instrumented. Paste at the top of your entrypoint, **before** importing the client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        from dotenv import load_dotenv
        load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

        from opentelemetry.instrumentation.google_generativeai import GoogleGenerativeAiInstrumentor
        from openobserve import openobserve_init

        GoogleGenerativeAiInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App
    description: "Make any Gemini call — your app already has its `GOOGLE_API_KEY` configured:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        client.models.generate_content(
            model="gemini-2.0-flash",
            contents="hi",
        )

  - title: Check OpenObserve
    description: "Open **Traces** and filter `gen_ai_provider_name = gcp.gen_ai`. Each call appears as a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai.request.model
      - gen_ai.usage.input_tokens
      - gen_ai.usage.output_tokens
      - llm.usage.cost_total

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-instrumentation-google-generativeai
    - google-genai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
---

# Google Gemini

Trace every Gemini API call from your Python app. The OpenObserve Data Sources
panel renders the stepped setup card from the frontmatter above.
