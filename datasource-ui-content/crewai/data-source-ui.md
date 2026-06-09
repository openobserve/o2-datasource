# CrewAI

**AI / Frameworks · Python 3.10–3.13** — Trace every crew, agent, task, and tool execution.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | bash -s -- \
  --integration=crewai \
  --url={url} \
  --org={org} \
  --token="Basic {token}"
```

Installs `openobserve-telemetry-sdk`, `openinference-instrumentation-crewai`, `crewai>=1.10.1`, `python-dotenv`, then writes `OPENOBSERVE_URL`, `OPENOBSERVE_ORG`, and `OPENOBSERVE_AUTH_TOKEN` to `./.env`.

## 2. Add to your app

Put these lines at the top of your entrypoint, **before** importing CrewAI:

```python
from dotenv import load_dotenv
load_dotenv()  # loads the OPENOBSERVE_* vars the installer wrote to .env

import os
os.environ["CREWAI_TELEMETRY_OPT_OUT"] = "true"

from openobserve import openobserve_init
openobserve_init()

from openinference.instrumentation.crewai import CrewAIInstrumentor
CrewAIInstrumentor().instrument()
```

`load_dotenv()` is required — `openobserve_init()` reads its settings from environment variables, not from `.env` directly.

## 3. Run your app

Kick off any crew — your app already has the underlying model's API key configured (e.g. `OPENAI_API_KEY`):

```python
crew.kickoff()
```

## 4. Check OpenObserve

Open **Traces** and filter for spans named `Crew_<uuid>.kickoff`. You'll see the full crew run — agents, tasks, and tool calls — as a span tree.

---

Run into issues? See the [docs](https://openobserve.ai/docs/integration/ai/frameworks/crewai/) or reach out to us on [Slack](https://short.openobserve.ai/community).
