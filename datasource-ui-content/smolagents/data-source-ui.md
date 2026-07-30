---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: SmolAgents
  logo: logo.svg
  tagline: "Trace SmolAgents runs, tool executions, code steps, and LLM calls."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenInference SmolAgents instrumentor
  # emits LLM spans named LiteLLMModel.generate, mapped to operation_name.
  filter: "operation_name = 'LiteLLMModel.generate'"
  model_label: openai/gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/smolagents/
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
    description: "Install the SDK + SmolAgents instrumentor, then instrument **before** importing SmolAgents. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Call SmolagentsInstrumentor().instrument() before importing smolagents — instrumenting after import means spans never flow."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-smolagents "smolagents[litellm]" python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.smolagents import SmolagentsInstrumentor
        from openobserve import openobserve_init

        SmolagentsInstrumentor().instrument()
        openobserve_init()

        import os
        from smolagents import CodeAgent, LiteLLMModel

        model = LiteLLMModel(
            model_id="openai/gpt-4o-mini",
            api_key=os.environ["OPENAI_API_KEY"],
        )
        agent = CodeAgent(tools=[], model=model)

  - title: Run Your App & Test
    description: "Make any agent run, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        result = agent.run("What is the square root of 144?")
        print(result)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = LiteLLMModel.generate`. Each agent run produces a root span with child LLM spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_usage_cost_input

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-smolagents
    - smolagents[litellm]
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing SmolAgents"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so init runs first:"
fix_snippet: |
  # instrument FIRST — before importing smolagents
  SmolagentsInstrumentor().instrument()
  openobserve_init()

  # only then import and use smolagents
  from smolagents import CodeAgent, LiteLLMModel

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move SmolagentsInstrumentor().instrument() and openobserve_init() above any smolagents import."
  - q: "Spans appear but the filter matches nothing"
    a: "The LLM span name depends on the model class (here LiteLLMModel.generate). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# SmolAgents

Trace HuggingFace SmolAgents runs to OpenObserve via OpenTelemetry using the
OpenInference instrumentor. The Data Sources panel renders the stepped setup
card from the frontmatter above.
