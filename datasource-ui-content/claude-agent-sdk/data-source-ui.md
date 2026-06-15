---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# The frontmatter below IS the card (provider + steps + live detection). Adding a
# `card:` + `detect:` block is what turns this integration into the rich card.
card:
  name: Claude Agent SDK
  tagline: Trace every agent run — token usage, turn counts, error status.
  runtime: Python 3.10–3.13
  setup_time: ~2 min
  tone: "#d97757"

# Live detection — "listening for the first span". The card polls a cheap COUNT
# over this stream/filter (windowed to listen-time). `stream` MUST match the
# stream the install command writes to (today the SDK default "default").
detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest
  filter: "operation_name = 'claude_agent.query'"

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/claude-agent-sdk/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Run The Installer
    description: "One command installs the SDK + telemetry packages and writes your `.env`. Safe to re-run."
    chip: { kind: terminal, label: Terminal }
    complete_on: copy
    code:
      lang: bash
      download_env: true
      text: |
        curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
          --integration=claude-agent-sdk \
          --url={url} \
          --org={org} \
          --token="Basic {token}"
    note: "You also need the Claude Code CLI on PATH — the SDK runs it as a subprocess: `npm install -g @anthropic-ai/claude-code`."

  - title: Add These Lines To Your App
    description: "Required — paste at the top of your entrypoint, **before** importing the SDK, then wrap each `query()` call in a manual span."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        from dotenv import load_dotenv
        load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

        tracer = trace.get_tracer(__name__)

        # Wrap each query() call in a manual span:
        async def run_agent(prompt):
            options = ClaudeAgentOptions(max_turns=1, allowed_tools=[])
            with tracer.start_as_current_span("claude_agent.query") as span:
                span.set_attribute("claude_agent.prompt", prompt[:100])
                async for message in query(prompt=prompt, options=options):
                    if isinstance(message, ResultMessage):
                        span.set_attribute("claude_agent.num_turns", message.num_turns)
                        span.set_attribute("claude_agent.is_error", message.is_error)
                        if message.usage:
                            span.set_attribute("claude_agent.input_tokens",
                                               message.usage.get("input_tokens", 0))
                            span.set_attribute("claude_agent.output_tokens",
                                               message.usage.get("output_tokens", 0))

  - title: Run Your App
    description: "Run a query through the Claude Agent SDK — your app already has its `ANTHROPIC_API_KEY` configured:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import asyncio

        asyncio.run(run_agent("In one sentence, what is OpenObserve?"))

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = claude_agent.query`. You'll see a span per query with the agent's turns/tool calls:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - claude_agent.num_turns
      - claude_agent.is_error
      - claude_agent.input_tokens
      - claude_agent.output_tokens

extras:
  installs:
    - openobserve-telemetry-sdk
    - claude-agent-sdk
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
---

# Claude Agent SDK

Trace every agent run — token usage, turn counts, error status. The OpenObserve
Data Sources panel renders the stepped setup card from the frontmatter above.
