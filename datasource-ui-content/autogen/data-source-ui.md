---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: AutoGen
  logo: logo.svg
  tagline: "Trace AutoGen multi-agent conversations, agent turns, LLM calls, and tool executions."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. AutoGen's OpenInference instrumentor emits
  # AGENT spans whose operation_name is the agent class name (e.g. AssistantAgent).
  filter: "operation_name = 'AssistantAgent'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/autogen/
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
        # your model provider key
        OPENAI_API_KEY=your-openai-key

  - title: Install & Instrument
    description: "Install the SDK + AutoGen instrumentor, then call `AutogenInstrumentor().instrument()` **before** importing AutoGen. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-autogen "ag2==0.9.0" python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.autogen import AutogenInstrumentor
        from openobserve import openobserve_init

        AutogenInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Start a conversation, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import os
        import autogen

        config_list = [{"model": "gpt-4o-mini", "api_key": os.environ["OPENAI_API_KEY"]}]

        assistant = autogen.AssistantAgent(
            name="assistant",
            llm_config={"config_list": config_list},
            system_message="You are a helpful assistant. Keep answers brief.",
        )
        user = autogen.UserProxyAgent(
            name="user",
            human_input_mode="NEVER",
            max_consecutive_auto_reply=1,
            is_termination_msg=lambda x: True,
        )
        user.initiate_chat(assistant, message="Explain OpenTelemetry in one sentence.")

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = AssistantAgent`. Each conversation produces a root span with child AGENT and LLM spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - openinference_span_kind
      - agent_type
      - llm_observation_type

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-autogen
    - ag2
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing AutoGen"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing autogen
  AutogenInstrumentor().instrument()
  openobserve_init()

  # only then import and use autogen
  import autogen

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move AutogenInstrumentor().instrument() and openobserve_init() above any autogen import."
  - q: "ImportError on autogen"
    a: "Install ag2 (the maintained fork) — it imports as autogen. Older pyautogen may conflict; uninstall it first."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# AutoGen

Trace AutoGen multi-agent conversations, agent turns, LLM calls, and tool
executions to OpenObserve via OpenTelemetry. The Data Sources panel renders the
stepped setup card from the frontmatter above; this body is human-readable notes
only.
