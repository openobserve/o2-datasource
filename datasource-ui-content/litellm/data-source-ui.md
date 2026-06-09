# LiteLLM

**AI / Frameworks · Python 3.10–3.13** — Trace LLM calls across 100+ providers via a unified interface.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=litellm \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `openinference-instrumentation-litellm`, `litellm`, `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing LiteLLM:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from openinference.instrumentation.litellm import LiteLLMInstrumentor
from openobserve import openobserve_init

LiteLLMInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run your app

Make any LiteLLM call — your app already has the target provider's API key configured (e.g. `OPENAI_API_KEY`):

```python
import litellm
litellm.completion(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "hi"}],
)
```

## 4. Check OpenObserve

Open **Traces** and filter `operation_name=completion`. You'll see a span per LiteLLM call with model, token usage, and cost.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/gateways/litellm-proxy/) or reach out to us on [Slack](https://short.openobserve.ai/community).
