# Google Gemini

**AI / Providers · Python 3.10–3.13** — Trace every Gemini API call from your Python app.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=gemini \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `opentelemetry-instrumentation-google-generativeai`, `google-genai`, `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing the client:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from opentelemetry.instrumentation.google_generativeai import GoogleGenerativeAiInstrumentor
from openobserve import openobserve_init

GoogleGenerativeAiInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run your app

Make any Gemini call — your app already has its `GOOGLE_API_KEY` configured:

```python
client.models.generate_content(
    model="gemini-2.0-flash",
    contents="hi",
)
```

## 4. Check OpenObserve

Open **Traces** and filter `gen_ai_provider_name=gcp.gen_ai`. You'll see a span per Gemini call with `gen_ai.request.model`, token usage, and cost attributes.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/providers/google-gemini/) or reach out to us on [Slack](https://short.openobserve.ai/community).
