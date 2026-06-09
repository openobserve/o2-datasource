# OpenRouter

**AI / Gateways · Python 3.10–3.13** — Trace LLM calls routed through 200+ provider models via a single endpoint.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=openrouter \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `openinference-instrumentation-openai`, `openai`, `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the client:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from openinference.instrumentation.openai import OpenAIInstrumentor
from openobserve import openobserve_init

OpenAIInstrumentor().instrument()
openobserve_init()
```

Then create the OpenAI client pointed at OpenRouter:

```python
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["OPENROUTER_API_KEY"],
    base_url="https://openrouter.ai/api/v1",
    # default_headers is OPTIONAL — only for OpenRouter's app-attribution
    # leaderboard. Omit it, or set your own app's URL/name.
    default_headers={
        "HTTP-Referer": "https://your-app.example.com",
        "X-Title": "Your App",
    },
)
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Make an OpenRouter call

Your app already has `OPENROUTER_API_KEY` configured. Use the client from section 2:

```python
response = client.chat.completions.create(
    model="openai/gpt-4o-mini",
    messages=[{"role": "user", "content": "Hello from OpenRouter!"}],
)

print(response.choices[0].message.content)
```

## 4. Check OpenObserve

Open **Traces** and filter where `llm_model_name` contains a `/` (e.g. `openai/gpt-4o-mini`) — OpenRouter model ids are namespaced. You'll see a span per call with model, token usage, and cost.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/gateways/openrouter/) or reach out to us on [Slack](https://short.openobserve.ai/community).
