---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: mcp-use
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace mcp-use agent runs: prompt input, MCP server, result length, and errors."
  runtime: Python 3.11+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each agent run is wrapped in a manual span
  # named mcp_use.agent_run, which OpenObserve maps to operation_name.
  filter: "operation_name = 'mcp_use.agent_run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/tools/mcp-use/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and OpenAI key."
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
    description: "Install the SDK + mcp-use, call `openobserve_init()` **before** importing `mcp_use`, then wrap each agent run in a manual span. Node.js is required to run MCP servers via `npx`. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk mcp-use langchain-openai opentelemetry-api python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os
        import asyncio
        from mcp_use import MCPClient, MCPAgent
        from langchain_openai import ChatOpenAI

        tracer = trace.get_tracer(__name__)

        config = {"mcpServers": {"filesystem": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        }}}

        llm = ChatOpenAI(model="gpt-4o-mini", api_key=os.environ["OPENAI_API_KEY"])

  - title: Run It & Test
    description: "Run one agent invocation, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        async def run(prompt: str):
            with tracer.start_as_current_span("mcp_use.agent_run") as span:
                span.set_attribute("mcp_use.prompt", prompt[:200])
                span.set_attribute("mcp_use.server", "filesystem")
                client = MCPClient(config)
                agent = MCPAgent(llm=llm, client=client, max_steps=5)
                result = await agent.run(prompt)
                span.set_attribute("mcp_use.result_length", len(str(result)))
                span.set_attribute("span_status", "OK")
                return result

        async def main():
            print(await run("What directories are available in /tmp?"))
            trace.get_tracer_provider().force_flush()

        asyncio.run(main())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = mcp_use.agent_run`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - mcp_use_prompt
      - mcp_use_server
      - mcp_use_result_length

extras:
  installs:
    - openobserve-telemetry-sdk
    - mcp-use
    - langchain-openai
    - opentelemetry-api
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Initialize Before Importing mcp_use"
fix_body: "If your app runs but no spans appear, init loaded too late. Re-order so openobserve_init() runs first:"
fix_snippet: |
  # init FIRST — before importing mcp_use
  from openobserve import openobserve_init
  openobserve_init()

  # only then import and use mcp_use inside manual spans
  from mcp_use import MCPClient, MCPAgent

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() above any mcp_use import, wrap each run in a manual span, and force_flush() before exit."
  - q: "MCP server fails to start"
    a: "Ensure Node.js is installed so `npx` can launch the MCP server (e.g. @modelcontextprotocol/server-filesystem)."
  - q: "ImportError or version errors from mcp-use"
    a: "mcp-use requires Python 3.11+. Use a virtualenv on a compatible interpreter."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# mcp-use

Trace mcp-use agent runs connecting LLM agents to MCP servers, to OpenObserve
via OpenTelemetry. The Data Sources panel renders the stepped setup card from
the frontmatter above; this body is human-readable notes only.
