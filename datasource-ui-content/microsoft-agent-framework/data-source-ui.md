---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Microsoft Agent Framework
  tagline: "Trace Microsoft Agent Framework runs with latency, input metadata, output size, and error details."
  runtime: Python 3.10+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # The instrumentation wraps each agent.run() in a manual span named
  # agent_framework.run, stored as operation_name.
  filter: "operation_name = 'agent_framework.run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/microsoft-agent-framework/
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
    description: "Install the SDK + Agent Framework, then call `openobserve_init()` to set up the tracer provider and wrap each `agent.run()` in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk agent-framework agent-framework-openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init(resource_attributes={"service.name": "microsoft-agent-framework"})

        from opentelemetry import trace
        tracer = trace.get_tracer(__name__)

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
        import os
        from agent_framework import Agent
        from agent_framework_openai import OpenAIChatClient

        client = OpenAIChatClient(api_key=os.environ["OPENAI_API_KEY"], model="gpt-4o-mini")
        agent = Agent(client=client)

        async def main():
            with tracer.start_as_current_span("agent_framework.run") as span:
                span.set_attribute("agent.input", "What is distributed tracing?")
                result = await agent.run("What is distributed tracing?")
                output = result.text if hasattr(result, "text") else str(result)
                span.set_attribute("agent.output_length", len(output))
                span.set_attribute("span_status", "OK")
            print(output)

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = agent_framework.run`. Each agent run carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - agent_input
      - agent_output_length
      - service_name

extras:
  installs:
    - openobserve-telemetry-sdk
    - agent-framework
    - agent-framework-openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Running the Agent"
fix_body: "If your app runs but no spans appear, openobserve_init() ran too late or the span was never created. Initialize first and wrap each run:"
fix_snippet: |
  # initialize FIRST
  openobserve_init(resource_attributes={"service.name": "microsoft-agent-framework"})

  # wrap each agent.run() in a span
  with tracer.start_as_current_span("agent_framework.run") as span:
      result = await agent.run("...")

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before creating the agent and ensure the agent.run() call happens inside a tracer.start_as_current_span() block."
  - q: "ModuleNotFoundError on agent_framework_openai"
    a: "Install both agent-framework and agent-framework-openai. The OpenAI client lives in the second package."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Microsoft Agent Framework

Trace Microsoft Agent Framework runs to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
