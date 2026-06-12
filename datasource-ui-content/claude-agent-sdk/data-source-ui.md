# Claude Agent SDK

**AI / SDKs · Python 3.10–3.13** — Trace every agent run — token usage, turn counts, error status.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=claude-agent-sdk \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `claude-agent-sdk`, and `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

You also need the **Claude Code CLI** on PATH — the SDK runs it as a subprocess:

```bash
npm install -g @anthropic-ai/claude-code
```

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the SDK:

```python
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
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run your app

Run a query through the Claude Agent SDK — your app already has its `ANTHROPIC_API_KEY` configured.

```python
import asyncio

asyncio.run(run_agent("In one sentence, what is OpenObserve?"))
```

## 4. Check OpenObserve

Open **Traces** and filter `operation_name=claude_agent.query`. You'll see a span per query with the agent's turns/tool calls.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/frameworks/claude-agent-sdk/) or reach out to us on [Slack](https://short.openobserve.ai/community).
