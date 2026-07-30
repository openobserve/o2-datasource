---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: BeeAI
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace BeeAI ReAct agent runs with latency, model name, question input, and response details."
  runtime: Python 3.11+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # The instrumentation wraps each agent.run() in a manual span named
  # beeai.agent_run, stored as operation_name.
  filter: "operation_name = 'beeai.agent_run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/beeai/
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
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + BeeAI, then call `openobserve_init()` **before** importing BeeAI and wrap each `agent.run()` in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install beeai-framework openai openobserve-telemetry-sdk python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        from beeai_framework.agents.react.agent import ReActAgent
        from beeai_framework.backend.chat import ChatModel
        from beeai_framework.memory.unconstrained_memory import UnconstrainedMemory

        tracer = trace.get_tracer(__name__)
        model = ChatModel.from_name("openai:gpt-4o-mini")

  - title: Run Your App & Test
    description: "Run an agent inside a manual span, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import asyncio

        async def run_agent(question: str) -> str:
            with tracer.start_as_current_span("beeai.agent_run") as span:
                span.set_attribute("beeai.question", question[:200])
                span.set_attribute("beeai.model", "gpt-4o-mini")
                agent = ReActAgent(llm=model, tools=[], memory=UnconstrainedMemory())
                response = await agent.run(question)
                result = response.last_message.text
                span.set_attribute("beeai.response_length", len(result))
                span.set_attribute("span_status", "OK")
                return result

        async def main():
            print(await run_agent("Explain distributed tracing in one sentence."))
            trace.get_tracer_provider().force_flush()

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = beeai.agent_run`. Each agent run carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - beeai_model
      - beeai_question
      - beeai_response_length

extras:
  installs:
    - beeai-framework
    - openai
    - openobserve-telemetry-sdk
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Flush Spans Before Exit"
fix_body: "If your app runs but no spans appear, the process may exit before the batch exporter flushes. Force a flush after the run:"
fix_snippet: |
  from opentelemetry import trace
  # after running your agent
  trace.get_tracer_provider().force_flush()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before importing BeeAI, and force_flush() the tracer provider before the process exits."
  - q: "beeai-framework fails to install"
    a: "BeeAI requires Python 3.11+. Check your interpreter version and use a 3.11+ virtualenv."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# BeeAI

Trace BeeAI ReAct agent runs to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
