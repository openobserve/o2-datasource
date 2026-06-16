---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LangChain DeepAgents
  tagline: "Trace DeepAgents runs with LangChain/LangGraph call chains, message counts, and LLM spans."
  runtime: Python 3.11+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # The instrumentation wraps each agent.invoke() in a manual root span named
  # deepagents.invoke, stored as operation_name.
  filter: "operation_name = 'deepagents.invoke'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/deepagents/
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
    description: "Install the SDK + LangChain instrumentor, then call `LangChainInstrumentor().instrument()` **before** `openobserve_init()`. DeepAgents builds on LangGraph, so all LangChain/LangGraph calls are auto-traced. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-langchain deepagents langchain-openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.langchain import LangChainInstrumentor
        LangChainInstrumentor().instrument()

        from openobserve import openobserve_init, openobserve_shutdown
        openobserve_init(resource_attributes={"service.name": "my-app"})

  - title: Run Your App & Test
    description: "Invoke a deep agent inside a manual span, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        from opentelemetry import trace
        from langchain_openai import ChatOpenAI
        from deepagents import create_deep_agent

        tracer = trace.get_tracer(__name__)
        model = ChatOpenAI(model="gpt-4o-mini", temperature=0)
        agent = create_deep_agent(model=model, tools=[])

        with tracer.start_as_current_span("deepagents.invoke") as span:
            span.set_attribute("deepagents.question", "What is distributed tracing?")
            result = agent.invoke({
                "messages": [{"role": "user", "content": "What is distributed tracing?"}]
            })
            messages = result.get("messages", [])
            span.set_attribute("deepagents.message_count", len(messages))
            span.set_attribute("span_status", "OK")
            print(messages[-1].content[:80] if messages else "")

        openobserve_shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = deepagents.invoke`. Each run produces a root span with the full LangGraph child tree carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - deepagents_question
      - deepagents_message_count
      - span_status

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-langchain
    - deepagents
    - langchain-openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing DeepAgents"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the LangChain instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before importing deepagents/langchain
  LangChainInstrumentor().instrument()
  openobserve_init(resource_attributes={"service.name": "my-app"})

  # only then import and use deepagents
  from deepagents import create_deep_agent

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move LangChainInstrumentor().instrument() and openobserve_init() above any deepagents/langchain import, and call openobserve_shutdown() at the end."
  - q: "Root span appears but no child LLM/LangGraph spans"
    a: "Ensure openinference-instrumentation-langchain is installed and instrument() ran before the agent was created."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# LangChain DeepAgents

Trace DeepAgents runs to OpenObserve via OpenTelemetry. The Data Sources panel
renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
