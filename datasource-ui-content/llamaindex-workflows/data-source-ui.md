---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: LlamaIndex Workflows
  tagline: "Trace LlamaIndex Workflow runs with step-by-step execution spans and LLM calls."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Async LLM calls inside steps store
  # operation_name as OpenAI.acomplete.
  filter: "operation_name = 'OpenAI.acomplete'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/llamaindex-workflows/
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
    description: "Install the SDK + LlamaIndex instrumentor, then call `LlamaIndexInstrumentor().instrument()` **before** importing LlamaIndex components. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly. Pin llama-index-core to 0.10.68 on Python 3.9."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve "openinference-instrumentation-llama-index==2.2.4" "llama-index-core==0.10.68" "llama-index-llms-openai==0.1.31" python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.llama_index import LlamaIndexInstrumentor
        from openobserve import openobserve_init

        LlamaIndexInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Run a workflow, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import os
        import asyncio
        from llama_index.core.workflow import Workflow, StartEvent, StopEvent, step, Event
        from llama_index.llms.openai import OpenAI

        class QuestionEvent(Event):
            question: str

        class QAWorkflow(Workflow):
            @step
            async def start(self, ev: StartEvent) -> QuestionEvent:
                return QuestionEvent(question=ev.get("question", "What is AI?"))

            @step
            async def answer(self, ev: QuestionEvent) -> StopEvent:
                llm = OpenAI(model="gpt-4o-mini", api_key=os.environ["OPENAI_API_KEY"])
                response = await llm.acomplete(f"Answer briefly: {ev.question}")
                return StopEvent(result=str(response))

        async def main():
            workflow = QAWorkflow(timeout=30, verbose=False)
            result = await workflow.run(question="Explain distributed tracing in one sentence.")
            print(result)

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and look for the workflow root span with per-step child spans. Each LLM step (e.g. `OpenAI.acomplete`) carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_usage_tokens_input
      - llm_usage_tokens_output

extras:
  installs:
    - openobserve
    - openinference-instrumentation-llama-index
    - llama-index-core
    - llama-index-llms-openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing LlamaIndex"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before importing llama_index components
  LlamaIndexInstrumentor().instrument()
  openobserve_init()

  # only then import and use llama_index workflows
  from llama_index.core.workflow import Workflow

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move LlamaIndexInstrumentor().instrument() and openobserve_init() above any llama_index import."
  - q: "Spans appear but the filter matches nothing"
    a: "The LLM span name depends on the call method (e.g. OpenAI.acomplete vs OpenAI.chat). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "SyntaxError or import errors on Python 3.9"
    a: "Pin llama-index-core to 0.10.68 and the instrumentor to 2.2.4. Later versions need Python 3.10+."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# LlamaIndex Workflows

Trace LlamaIndex Workflow runs to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
