---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Strands Agents
  tagline: "Trace Strands agent runs, event-loop cycles, and LLM calls with token usage."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The manual root span is named "strands.agent"
  # (mapped to operation_name); Strands also emits invoke_agent/chat spans.
  filter: "operation_name = 'strands.agent'"
  model_label: claude-haiku-4-5

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/strands-agents/
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
        ANTHROPIC_API_KEY=your-anthropic-api-key

  - title: Install & Instrument
    description: "Install the SDK + Strands Agents, call `openobserve_init()`, then wrap each agent call in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables. Strands creates child invoke_agent / event-loop / chat spans automatically."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk strands-agents python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        from strands import Agent
        from strands.models.anthropic import AnthropicModel

        tracer = trace.get_tracer(__name__)

        model = AnthropicModel(model_id="claude-haiku-4-5-20251001", max_tokens=1000)
        agent = Agent(model=model)

  - title: Run Your App & Test
    description: "Make any agent call inside the span, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        with tracer.start_as_current_span("strands.agent") as span:
            span.set_attribute("input_value", "What is OpenTelemetry?")
            response = agent("What is OpenTelemetry?")
            output = str(response)
            span.set_attribute("output_value", output[:200])

        print(output)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = strands.agent`. Expand the tree to the `chat` / `invoke_agent` spans, which carry:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_request_model
      - gen_ai_usage_input_tokens
      - gen_ai_usage_total_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - strands-agents
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Wrapping Calls"
fix_body: "If your app runs but no spans appear, the tracer provider wasn't set up first. Re-order so init runs before the agent call:"
fix_snippet: |
  # initialize FIRST — registers the tracer provider
  openobserve_init()

  # only then get the tracer and wrap your agent call
  tracer = trace.get_tracer(__name__)

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before creating the tracer or invoking the agent."
  - q: "Spans appear but the filter matches nothing"
    a: "The manual root span name is whatever you pass to start_as_current_span (here strands.agent). Open Traces, read the actual operation_name, and adjust the filter."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Strands Agents

Trace Strands Agents runs to OpenObserve via OpenTelemetry. Strands emits agent,
event-loop, and LLM spans automatically; a manual root span attaches your own
input/output. The Data Sources panel renders the stepped setup card from the frontmatter.
