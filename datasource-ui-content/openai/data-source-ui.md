# OpenAI

**AI / Providers · Python 3.10–3.13** — trace every OpenAI Python SDK call.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=openai \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `opentelemetry-instrumentation-openai`,
`openai`, and `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`,
and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the OpenAI client:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from opentelemetry.instrumentation.openai import OpenAIInstrumentor
from openobserve import openobserve_init

OpenAIInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from
environment variables, not from `.env` directly.

## 3. Run your app

Make any OpenAI call — your app already has its `OPENAI_API_KEY` configured:

```python
client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "hi"}],
)
```

## 4. Check OpenObserve

Open **Traces** and filter `gen_ai_system=openai`. You'll see spans like `openai.chat` with `gen_ai.request.model`, token usage, and cost attributes.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/providers/openai/) or reach out to us on [Slack](https://short.openobserve.ai/community).
