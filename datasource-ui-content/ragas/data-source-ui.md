---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Ragas
  tagline: "Trace Ragas RAG evaluations: scores, latency, and per-run metadata."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Ragas has no OTel instrumentor; each scoring
  # call is wrapped in a manual span named "ragas.evaluate".
  filter: "operation_name = 'ragas.evaluate'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/ragas/
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
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + Ragas, call `openobserve_init()`, then wrap each metric scoring call in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Ragas 0.4.x uses an async scoring API — pass an instructor-wrapped AsyncOpenAI client and call ascore() inside asyncio.run()."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk ragas instructor python-dotenv
        import asyncio
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        import os
        import instructor
        from openai import AsyncOpenAI
        from opentelemetry import trace
        from ragas.llms import LiteLLMStructuredLLM
        from ragas.metrics.collections import Faithfulness

        tracer = trace.get_tracer(__name__)

        oai = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])
        client = instructor.from_openai(oai)
        llm = LiteLLMStructuredLLM(client=client, model="gpt-4o-mini", provider="openai")
        faithfulness_metric = Faithfulness(llm=llm)

        async def evaluate_sample(user_input, response, retrieved_contexts):
            with tracer.start_as_current_span("ragas.evaluate") as span:
                span.set_attribute("ragas.question", user_input)
                span.set_attribute("ragas.metrics", "faithfulness")
                result = await faithfulness_metric.ascore(
                    user_input=user_input,
                    response=response,
                    retrieved_contexts=retrieved_contexts,
                )
                span.set_attribute("ragas.faithfulness", float(result.value))
            print(f"Faithfulness: {result.value:.2f}")

  - title: Run Your App & Test
    description: "Run an evaluation, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        asyncio.run(evaluate_sample(
            user_input="What is OpenTelemetry?",
            response="OpenTelemetry is a vendor-neutral observability framework.",
            retrieved_contexts=["OpenTelemetry provides APIs and SDKs for tracing, metrics, and logging."],
        ))

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = ragas.evaluate`. Each evaluation span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - ragas_question
      - ragas_metrics
      - ragas_faithfulness

extras:
  installs:
    - openobserve-telemetry-sdk
    - ragas
    - instructor
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Wrapping Calls"
fix_body: "If your app runs but no spans appear, the tracer provider wasn't set up first. Re-order so init runs before scoring:"
fix_snippet: |
  # initialize FIRST — registers the tracer provider
  openobserve_init()

  # only then get the tracer and wrap your ascore() call
  tracer = trace.get_tracer(__name__)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before creating the tracer or wrapping any scoring call."
  - q: "Spans appear but the filter matches nothing"
    a: "The span name is whatever you pass to start_as_current_span (here ragas.evaluate). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "ascore() raises about a missing async client"
    a: "Ragas 0.4.x needs an AsyncOpenAI client wrapped with instructor and called inside asyncio.run()."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Ragas

Trace Ragas RAG evaluation runs to OpenObserve via OpenTelemetry. Ragas has no
dedicated instrumentor, so scoring calls are wrapped in manual spans. The Data
Sources panel renders the stepped setup card from the frontmatter above.
