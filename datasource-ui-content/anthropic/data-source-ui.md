# Anthropic

**AI / Providers · Python 3.10–3.13** — Trace every Claude API call from your Python app.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=anthropic \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `opentelemetry-instrumentation-anthropic`, `anthropic`, and `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the client:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from opentelemetry.instrumentation.anthropic import AnthropicInstrumentor
from openobserve import openobserve_init

AnthropicInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run your app

Make any Anthropic call — your app already has its `ANTHROPIC_API_KEY` configured:

```python
client.messages.create(
    model="claude-haiku-4-5",
    max_tokens=100,
    messages=[{"role": "user", "content": "hi"}],
)
```

## 4. Check OpenObserve

Open **Traces** and filter `gen_ai_system=Anthropic`. You'll see spans for each Claude call with model, token usage, and cost attributes.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/providers/anthropic/) or reach out to us on [Slack](https://short.openobserve.ai/community).
