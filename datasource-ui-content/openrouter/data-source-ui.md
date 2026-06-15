---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: OpenRouter
  tagline: Trace LLM calls routed through 200+ provider models via a single endpoint.
  runtime: Python 3.10–3.13
  setup_time: ~2 min
  tone: "#6366f1"

# Live detection — "listening for the first span". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). `stream` MUST match the
# stream the install command writes to (today the SDK default "default").
detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest
  filter: "llm_model_name LIKE '%/%'"
  model_label: openai/gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/gateways/openrouter/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command installs the SDK + OpenAI instrumentor and writes your `.env`. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      download_env: true
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
          --integration=openrouter \
          --url={url} \
          --org={org} \
          --token="Basic {token}"

  - title: Add These Lines To Your App
    description: "Required — paste at the top of your entrypoint, **before** importing the client, then create the OpenAI client pointed at OpenRouter."
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

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        from openai import OpenAI

        client = OpenAI(
            api_key=os.environ["OPENROUTER_API_KEY"],
            base_url="https://openrouter.ai/api/v1",
            # default_headers is OPTIONAL — only for OpenRouter's app-attribution
            # leaderboard. Omit it, or set your own app's URL/name.
            default_headers={
                "HTTP-Referer": "https://your-app.example.com",
                "X-Title": "Your App",
            },
        )

  - title: Run Your App
    description: "Make an OpenRouter call — your app already has its `OPENROUTER_API_KEY` configured:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        response = client.chat.completions.create(
            model="openai/gpt-4o-mini",
            messages=[{"role": "user", "content": "Hello from OpenRouter!"}],
        )

        print(response.choices[0].message.content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter where `llm_model_name` contains a `/` (e.g. `openai/gpt-4o-mini`) — OpenRouter model ids are namespaced. Each call appears as a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - gen_ai.usage.input_tokens
      - gen_ai.usage.output_tokens
      - llm.usage.cost_total

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
---

# OpenRouter

Trace LLM calls routed through 200+ provider models via a single endpoint. The
OpenObserve Data Sources panel renders the stepped setup card from the
frontmatter above.
