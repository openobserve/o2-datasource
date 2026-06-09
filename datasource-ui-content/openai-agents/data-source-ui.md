# OpenAI Agents SDK

**AI / Frameworks · Python 3.10–3.13** — trace every agent workflow, handoff, and LLM call.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=openai-agents \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `openinference-instrumentation-openai-agents`, `openai-agents`, and `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the Agents SDK:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from openinference.instrumentation.openai_agents import OpenAIAgentsInstrumentor
from openobserve import openobserve_init

OpenAIAgentsInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run a workflow

Your app already has `OPENAI_API_KEY` configured. Define an agent and run it — every call is traced automatically:

```python
from agents import Agent, Runner

agent = Agent(name="Assistant", instructions="You are a helpful assistant.")

result = Runner.run_sync(agent, "hi")
print(result.final_output)
```

## 4. Check OpenObserve

Open **Traces** and filter for spans named `Agent workflow`. You'll see the agent run — model calls, tool calls, handoffs — as a span tree.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/frameworks/openai-agents/) or reach out to us on [Slack](https://short.openobserve.ai/community).
