---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: OpenAI Assistants API
  tagline: "Trace OpenAI Assistants workflows: thread creation, run execution, message handling, and tokens."
  runtime: Python 3.8+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenInference OpenAI instrumentor traces
  # each Assistants API call as an LLM span with llm_provider='openai'.
  filter: "LOWER(llm_provider) = 'openai' AND openinference_span_kind = 'LLM'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/providers/openai-assistants/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and OpenAI key."
    chip: { kind: editor, label: .env }
    complete_on: copy
    code:
      lang: bash
      filename: .env
      download_env: true
      text: |
        OPENOBSERVE_URL={url}
        OPENOBSERVE_ORG={org}
        OPENOBSERVE_AUTH_TOKEN=Basic {token}
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Install the SDK + OpenAI instrumentor, then call `OpenAIInstrumentor().instrument()` **before** importing or instantiating the OpenAI client."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "load_dotenv() is required — openobserve_init() reads its settings from environment variables, not from .env directly."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-openai openai python-dotenv
        import time
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        OpenAIInstrumentor().instrument()
        openobserve_init()

        import os
        from openai import OpenAI

        client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

  - title: Run Your App & Test
    description: "Run an Assistants workflow, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        assistant = client.beta.assistants.create(
            name="Observability Assistant",
            instructions="Answer questions about observability concisely in one sentence.",
            model="gpt-4o-mini",
        )
        thread = client.beta.threads.create()
        client.beta.threads.messages.create(
            thread_id=thread.id, role="user", content="What is OpenTelemetry?",
        )
        run = client.beta.threads.runs.create(thread_id=thread.id, assistant_id=assistant.id)
        while run.status in ("queued", "in_progress"):
            time.sleep(0.5)
            run = client.beta.threads.runs.retrieve(thread_id=thread.id, run_id=run.id)
        messages = client.beta.threads.messages.list(thread_id=thread.id)
        print(messages.data[0].content[0].text.value)
        client.beta.assistants.delete(assistant.id)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `llm_provider = openai`. Each workflow produces a group of LLM spans carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - openinference_span_kind
      - llm_usage_tokens_input
      - llm_usage_tokens_output

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-openai
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - OPENAI_API_KEY

fix_title: "Instrument Before Importing The Client"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the instrumentor runs first:"
fix_snippet: |
  # instrument FIRST — before the OpenAI client is imported
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then import and use the client
  from openai import OpenAI

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move OpenAIInstrumentor().instrument() and openobserve_init() above the `from openai import OpenAI` line."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attributes — Assistants spans set llm_provider='openai' and openinference_span_kind='LLM'. Adjust the filter to match."
  - q: "The Assistants API is deprecated — is it still supported?"
    a: "Yes. OpenAI deprecated it in favour of the Responses API, but it still functions and is fully instrumented by the OpenAI instrumentor."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# OpenAI Assistants API

Trace OpenAI Assistants API workflows to OpenObserve via OpenTelemetry. The Data
Sources panel renders the stepped setup card from the frontmatter above; this
body is human-readable notes only.
