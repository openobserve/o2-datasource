---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Langserve
  logo: logo.svg
  tagline: "Trace LangServe RemoteRunnable calls from a Python client with end-to-end latency."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # Client-side RemoteRunnable calls store operation_name as RemoteRunnable.workflow.
  filter: "operation_name = 'RemoteRunnable.workflow'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/langserve/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and the LangServe URL."
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
        LANGSERVE_URL=http://localhost:8000

  - title: Install & Instrument
    description: "Install the SDK + LangChain instrumentor, then call `LangchainInstrumentor().instrument()` **before** instantiating `RemoteRunnable`. A running LangServe server is required. Full details in the docs."
    chip: { kind: editor, label: client.py }
    required: true
    complete_on: copy
    note: "Token counts are not available client-side because the LLM call runs on the server. Instrument the server with the same LangchainInstrumentor to capture token usage."
    code:
      lang: python
      filename: client.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-instrumentation-langchain langserve python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from opentelemetry.instrumentation.langchain import LangchainInstrumentor
        from openobserve import openobserve_init

        LangchainInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Call the remote chain, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: client.py
      text: |
        import os
        from langserve import RemoteRunnable

        chain = RemoteRunnable(
            f"{os.environ.get('LANGSERVE_URL', 'http://localhost:8000')}/chain/"
        )

        result = chain.invoke({"input": "What is OpenTelemetry?"})
        print(result)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = RemoteRunnable.workflow`. Each remote chain call produces a workflow span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_observation_type
      - traceloop_workflow_name
      - duration

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-instrumentation-langchain
    - langserve
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Creating RemoteRunnable"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so the init runs first:"
fix_snippet: |
  # instrument FIRST — before creating the RemoteRunnable
  LangchainInstrumentor().instrument()
  openobserve_init()

  # only then create and call the remote chain
  from langserve import RemoteRunnable

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move LangchainInstrumentor().instrument() and openobserve_init() above any RemoteRunnable creation."
  - q: "Spans appear but no token counts"
    a: "Token usage is recorded on the server, not the client. Instrument the LangServe server with the same LangchainInstrumentor."
  - q: "Connection refused / ERROR spans"
    a: "Make sure the LangServe server is running and LANGSERVE_URL points to it (default http://localhost:8000)."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Langserve

Trace LangServe RemoteRunnable calls from a Python client to OpenObserve via
OpenTelemetry. The Data Sources panel renders the stepped setup card from the
frontmatter above; this body is human-readable notes only.
