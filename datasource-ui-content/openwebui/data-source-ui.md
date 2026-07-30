---
# openwebui/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Open WebUI
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace Open WebUI chat completions: model, question, response length, and latency."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each chat call is wrapped in a manual span
  # named openwebui.chat_completion, which OpenObserve maps to operation_name.
  filter: "operation_name = 'openwebui.chat_completion'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/no-code/openwebui/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your Open WebUI base URL, API key, and model."
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
        OPENWEBUI_BASE_URL=http://localhost:3001
        OPENWEBUI_API_KEY=your-openwebui-api-key
        OPENWEBUI_MODEL=gpt-4o-mini

  - title: Install & Wrap The Chat Call
    description: "Run Open WebUI via Docker, generate an API key (profile > API Keys), install the SDK, init OpenObserve, then wrap each chat call in a manual span."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Start the UI first: docker run -d --name openwebui -p 3001:8080 -e OPENAI_API_KEY=your-openai-key ghcr.io/open-webui/open-webui:main"
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk python-dotenv requests
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os, requests

        tracer = trace.get_tracer(__name__)
        base_url = os.environ.get("OPENWEBUI_BASE_URL", "http://localhost:3001")
        api_key = os.environ["OPENWEBUI_API_KEY"]
        model = os.environ.get("OPENWEBUI_MODEL", "gpt-4o-mini")

  - title: Run It & Test
    description: "Send a chat completion, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        prompt = "Explain distributed tracing in one sentence."

        with tracer.start_as_current_span("openwebui.chat_completion") as span:
            span.set_attribute("openwebui.model", model)
            span.set_attribute("openwebui.question", prompt)
            resp = requests.post(
                f"{base_url}/api/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json={"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 100},
            )
            resp.raise_for_status()
            content = resp.json()["choices"][0]["message"]["content"]
            span.set_attribute("openwebui.response_length", len(content))

        print(content)

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = openwebui.chat_completion`. Each call produces a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - openwebui_model
      - openwebui_response_length
      - span_status

extras:
  installs:
    - openobserve-telemetry-sdk
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Init Before The First Chat Call"
fix_body: "If your app runs but no spans appear, init loaded too late. Call init first, then wrap the chat call:"
fix_snippet: |
  # init FIRST, before any chat call
  openobserve_init()
  tracer = trace.get_tracer(__name__)

  # only then wrap the chat completion
  with tracer.start_as_current_span("openwebui.chat_completion") as span:
      ...

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before the first chat call. Short scripts may exit before the exporter flushes — let the SDK shut down cleanly."
  - q: "401 from Open WebUI"
    a: "Generate an API key under your profile > API Keys and pass it as a Bearer token (OPENWEBUI_API_KEY)."
  - q: "Connection refused"
    a: "Confirm the container is running and OPENWEBUI_BASE_URL maps to the published port (the example maps host 3001 -> container 8080)."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Open WebUI

Trace Open WebUI chat completions to OpenObserve via OpenTelemetry by wrapping
its OpenAI-compatible API calls in manual spans. The Data Sources panel renders
the stepped setup card from the frontmatter above; this body is human-readable
notes only.
