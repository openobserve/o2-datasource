---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: CrewAI
  tagline: Trace every crew, agent, task, and tool execution.
  runtime: Python 3.10–3.13
  setup_time: ~2 min
  tone: "#ef6c3b"

# Live detection — "listening for the first span". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). `stream` MUST match the
# stream the install command writes to (today the SDK default "default").
detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest
  filter: "name LIKE 'Crew_%.kickoff'"

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/crewai/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command installs the SDK + CrewAI instrumentor and writes your `.env`. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      download_env: true
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
          --integration=crewai \
          --url={url} \
          --org={org} \
          --token="Basic {token}"

  - title: Add These Lines To Your App
    description: "Required — paste at the top of your entrypoint, **before** importing CrewAI."
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

        import os
        os.environ["CREWAI_TELEMETRY_OPT_OUT"] = "true"

        from openobserve import openobserve_init
        openobserve_init()

        from openinference.instrumentation.crewai import CrewAIInstrumentor
        CrewAIInstrumentor().instrument()

  - title: Run Your App
    description: "Kick off any crew — your app already has the underlying model's API key configured (e.g. `OPENAI_API_KEY`):"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        crew.kickoff()

  - title: Check OpenObserve
    description: "Open **Traces** and filter for spans named `Crew_<uuid>.kickoff`. You'll see the full crew run — agents, tasks, and tool calls — as a span tree."
    chip: { kind: traces, label: Traces }
    complete_on: detect

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-crewai
    - crewai>=1.10.1
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
---

# CrewAI

Trace every crew, agent, task, and tool execution from your Python app. The
OpenObserve Data Sources panel renders the stepped setup card from the
frontmatter above.
