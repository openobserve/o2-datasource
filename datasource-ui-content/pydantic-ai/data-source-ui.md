---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Pydantic AI
  tagline: "Trace Pydantic AI agent runs, tool calls, and structured-output extractions."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Pydantic AI uses its own (Logfire-based) OTel
  # schema; each run emits a span whose operation_name is "agent run".
  filter: "operation_name = 'agent run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/pydantic-ai/
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
        OPENAI_API_KEY=your-openai-key

  - title: Install & Instrument
    description: "Install the SDK + Pydantic AI, call `openobserve_init()` first, then `Agent.instrument_all()`. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables. Call openobserve_init() before instrument_all() so the global TracerProvider is registered first."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk pydantic-ai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from pydantic_ai import Agent
        Agent.instrument_all()

        agent = Agent("openai:gpt-4o-mini")

  - title: Run Your App & Test
    description: "Make any agent call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = agent.run_sync("Explain distributed tracing in one sentence.")
        print(result.output)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = agent run`. Each agent run produces a root span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - model_name
      - gen_ai_usage_input_tokens
      - gen_ai_usage_output_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - pydantic-ai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before instrument_all()"
fix_body: "If your app runs but no spans appear, the global TracerProvider wasn't registered first. Re-order:"
fix_snippet: |
  # initialize FIRST — registers the global TracerProvider
  openobserve_init()

  # only then enable tracing on all agents
  from pydantic_ai import Agent
  Agent.instrument_all()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before Agent.instrument_all(), and make sure instrument_all() runs before any agent.run_sync() call."
  - q: "Spans appear but the filter matches nothing"
    a: "Pydantic AI uses a Logfire-based schema; the operation_name is usually `agent run`. Open Traces, read the actual operation_name, and adjust the filter."
  - q: "Python 3.9 install fails"
    a: "Pin the SDK: pip install \"pydantic-ai==0.8.1\" — newer versions need Python 3.10+."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Pydantic AI

Trace Pydantic AI agent runs to OpenObserve via OpenTelemetry. Pydantic AI has
built-in OTel support — no separate instrumentor needed. The Data Sources panel
renders the stepped setup card from the frontmatter above.
