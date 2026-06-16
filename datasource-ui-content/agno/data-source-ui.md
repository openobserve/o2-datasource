---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: Agno
  tagline: "Trace Agno agent runs, tool calls, memory lookups, and LLM invocations."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Agno's OpenInference instrumentor emits an
  # LLM span named after the model class invoke (e.g. OpenAIChat.invoke), which
  # OpenObserve maps to operation_name. Adjust if you use a non-OpenAI model.
  filter: "operation_name = 'OpenAIChat.invoke'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/agno/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials."
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
        # your model provider key, e.g.
        OPENAI_API_KEY=your-openai-key

  - title: Install & Instrument
    description: "Install the SDK + Agno instrumentor, then instrument **before** importing Agno. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-agno agno python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.agno import AgnoInstrumentor
        from openobserve import openobserve_init

        AgnoInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Make any agent call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        from agno.agent import Agent
        from agno.models.openai import OpenAIChat

        agent = Agent(model=OpenAIChat(id="gpt-4o-mini"))
        print(agent.run("What is OpenTelemetry?").content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = OpenAIChat.invoke`. Each agent run produces a root span with child LLM/tool spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_usage_cost_input

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-agno
    - agno
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing Agno"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing agno
  AgnoInstrumentor().instrument()
  openobserve_init()

  # only then import and use agno
  from agno.agent import Agent

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move AgnoInstrumentor().instrument() and openobserve_init() above any agno import."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name depends on your model class (e.g. OpenAIChat.invoke). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Agno

Trace Agno agent runs, tool calls, memory lookups, and LLM invocations to
OpenObserve via OpenTelemetry. The Data Sources panel renders the stepped setup
card from the frontmatter above; this body is human-readable notes only.
