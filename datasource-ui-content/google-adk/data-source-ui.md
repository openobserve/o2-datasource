# Google ADK

**AI / Frameworks · Python 3.10–3.13** — Trace every ADK agent run, LLM call, and tool execution.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=google-adk \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `openinference-instrumentation-google-adk`, `google-adk`, `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the ADK:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from openinference.instrumentation.google_adk import GoogleADKInstrumentor
from openobserve import openobserve_init

GoogleADKInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run an agent

Define an agent and run it. Your app already has `GOOGLE_API_KEY` configured.

```python
from google.adk.agents import Agent
from google.adk.runners import InMemoryRunner
from google.genai import types

agent = Agent(
    name="assistant",
    model="gemini-2.0-flash",
    instruction="You are a helpful assistant.",
)

runner = InMemoryRunner(agent=agent, app_name="assistant")
session = runner.session_service.create_session(app_name="assistant", user_id="user")

for event in runner.run(
    user_id="user",
    session_id=session.id,
    new_message=types.Content(role="user", parts=[types.Part(text="What is OpenObserve?")]),
):
    if event.is_final_response():
        print(event.content.parts[0].text)
```

## 4. Check OpenObserve

Open **Traces** and filter for spans named `invocation [<app_name>]`. You'll see the agent invocation as a span tree (model calls, tools).

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/frameworks/google-adk/) or reach out to us on [Slack](https://short.openobserve.ai/community).
