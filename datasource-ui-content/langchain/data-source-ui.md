# LangChain / LangGraph — Data Sources UI panel content

What the OpenObserve **Data Sources → AI → LangChain** panel should render.

---

## Card metadata

| Field | Value |
|---|---|
| Display name | LangChain / LangGraph |
| Category | AI / Frameworks |
| Icon | `langchain.svg` |
| Tagline | Trace every chain, LLM call, tool invocation, and retrieval step |
| Supported runtime | Python 3.9+ |

## Section 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/openobserve-telemetry-installers/main/frameworks/setup.sh | bash -s -- \
  --integration=langchain \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

**What this does:** installs `openobserve-telemetry-sdk`,
`opentelemetry-instrumentation>=0.51b0`, `opentelemetry-instrumentation-langchain`,
`langchain-core`, `wrapt>=1.16,<2`, `python-dotenv`. Verifies the imports
work. Writes `OPENOBSERVE_*` keys to `.env`.

**Important compat note:** the LangChain instrumentor imports `wrapt`'s
`wrap_function_wrapper` as a positional-and-keyword call. `wrapt 2.x` made
the first arg positional-only, breaking the instrumentor. This installer
pins `wrapt<2` to avoid the break.

## Section 2 — Paste this into your app

```python
from opentelemetry.instrumentation.langchain import LangchainInstrumentor
from openobserve import openobserve_init

LangchainInstrumentor().instrument()
openobserve_init()
```

> Four lines at the top of your app entrypoint, **before** importing any
> LangChain modules.

Works for LangChain chains (`prompt | llm | StrOutputParser`), LangGraph
graphs (`StateGraph`), retrievers, tools, and any nested LLM call.

## Section 3 — Verify

> Invoke any chain: `chain.invoke({"question": "..."})`.

Open Traces, look for `langchain_request_type` spans. Each chain invocation
produces a root span with child spans for every LLM call, tool, and
retriever. Attributes include `gen_ai.request.model`,
`gen_ai.usage.input_tokens/output_tokens`, `llm.usage.cost_total`,
`langchain_tool_name`, `langchain_retriever_query`.

E2E example produced 4 spans for a `prompt | llm | output_parser` chain.

## Section 4 — Troubleshooting

| Symptom | Fix |
|---|---|
| `TypeError: wrap_function_wrapper() got an unexpected keyword argument 'module'` | wrapt 2.x is installed; the installer pins wrapt<2 but if you upgraded manually, run `pip install 'wrapt<2'` |
| `ModuleNotFoundError: langchain_core` | The installer adds `langchain-core` as a dep — re-run the installer |
| App runs but no chain spans | Move the four lines above all LangChain imports |

---

## Panel implementation notes

- Same panel template as the other framework cards.
- If the user already has `wrapt>=2` for other libraries, the installer will
  downgrade. Surface this in the install output (the panel could show a
  warning about wrapt downgrade as a "what to expect" note).

## Reference link

Full integration docs:
[openobserve-docs/docs/integration/ai/frameworks/langchain.md](../../openobserve-docs/docs/integration/ai/frameworks/langchain.md)

**Docs feedback to send back:** the existing doc's `pip install` line is
missing `langchain-core` and `wrapt<2`. Either:

- Update the doc to: `pip install openobserve-telemetry-sdk opentelemetry-instrumentation-langchain langchain-core 'wrapt<2' python-dotenv`
- Or document that users running a LangChain app already have these.
