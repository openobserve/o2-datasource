# LangChain / LangGraph

**AI / Frameworks · Python 3.10–3.13** — Trace every chain, LLM call, tool invocation, and retrieval step.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=langchain \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `opentelemetry-instrumentation>=0.51b0`, `opentelemetry-instrumentation-langchain`, `langchain-core`, `wrapt>=1.16,<2`, `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing LangChain:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

from opentelemetry.instrumentation.langchain import LangchainInstrumentor
from openobserve import openobserve_init

LangchainInstrumentor().instrument()
openobserve_init()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run your app

Invoke any LangChain/LangGraph chain — your app already has the underlying model's API key configured (e.g. `OPENAI_API_KEY`):

```python
from langchain_openai import ChatOpenAI
ChatOpenAI(model="gpt-4o-mini").invoke("hi")
```

## 4. Check OpenObserve

Open **Traces** and look for the chain's span tree — a top-level `<Chain>.workflow` span (e.g. `RunnableSequence.workflow`) with child spans like `ChatOpenAI.chat`. To filter, use the `traceloop_span_kind` attribute (`workflow` / `task` / `llm`).

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/frameworks/langchain/) or reach out to us on [Slack](https://short.openobserve.ai/community).
