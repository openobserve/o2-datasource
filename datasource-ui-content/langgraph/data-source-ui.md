---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LangGraph
  logo: logo.svg
  tagline: "Trace LangGraph graph executions, node transitions, and LLM calls with token usage and cost."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # LangGraph spans carry the traceloop workflow name LangGraph.
  filter: "traceloop_workflow_name = 'LangGraph'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/langgraph/
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
    description: "Install the SDK + LangChain instrumentor, then call `LangchainInstrumentor().instrument()` **before** importing LangGraph or LangChain. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-instrumentation-langchain langchain-openai langgraph python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from opentelemetry.instrumentation.langchain import LangchainInstrumentor
        from openobserve import openobserve_init

        LangchainInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Run a compiled graph, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        from typing import TypedDict
        from langchain_openai import ChatOpenAI
        from langgraph.graph import StateGraph, END

        llm = ChatOpenAI(model="gpt-4o-mini")

        class State(TypedDict):
            question: str
            answer: str

        def answer_node(state: State):
            response = llm.invoke([{"role": "user", "content": state["question"]}])
            return {"answer": response.content}

        graph = StateGraph(State)
        graph.add_node("answer", answer_node)
        graph.set_entry_point("answer")
        graph.add_edge("answer", END)
        app = graph.compile()

        result = app.invoke({"question": "What is OpenTelemetry?", "answer": ""})
        print(result["answer"])

  - title: Check OpenObserve
    description: "Open **Traces** and filter `traceloop_workflow_name = LangGraph`. Each graph execution produces a root span with per-node LLM spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - traceloop_association_properties_langgraph_node
      - gen_ai_request_model
      - gen_ai_usage_input_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-instrumentation-langchain
    - langchain-openai
    - langgraph
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing LangGraph"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing langgraph/langchain
  LangchainInstrumentor().instrument()
  openobserve_init()

  # only then import and use langgraph
  from langgraph.graph import StateGraph

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move LangchainInstrumentor().instrument() and openobserve_init() above any langgraph/langchain import."
  - q: "Spans appear but the filter matches nothing"
    a: "Confirm the spans carry traceloop_workflow_name = LangGraph. Open Traces and read the actual attribute if you customized the workflow name."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# LangGraph

Trace LangGraph graph executions, node transitions, and LLM calls to OpenObserve
via OpenTelemetry. The Data Sources panel renders the stepped setup card from the
frontmatter above; this body is human-readable notes only.
