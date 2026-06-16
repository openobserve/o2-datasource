---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
# Basic card: set env vars -> install & instrument (from docs) -> run & test.
card:
  name: LibreChat
  tagline: "Trace LibreChat API messages: endpoint, conversation ID, completion, and latency."
  runtime: Python 3.8+
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each message is wrapped in a manual span
  # named librechat.chat, which OpenObserve maps to operation_name.
  filter: "operation_name = 'librechat.chat'"

doc_url: https://openobserve.ai/docs/integration/ai/tools/librechat/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and LibreChat instance details."
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
        LIBRECHAT_BASE_URL=http://localhost:3080
        LIBRECHAT_EMAIL=your@email.com
        LIBRECHAT_PASSWORD=your-password

  - title: Install & Instrument
    description: "Install the SDK + requests, call `openobserve_init()` first, then log in to LibreChat and wrap each message in a manual span. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "LibreChat enforces a browser User-Agent on the chat endpoint — requests without one are rejected with `Illegal request`."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init, openobserve_shutdown
        openobserve_init(resource_attributes={"service.name": "my-app"})

        from opentelemetry import trace
        import os, time, requests

        tracer = trace.get_tracer(__name__)
        base_url = os.environ.get("LIBRECHAT_BASE_URL", "http://localhost:3080")
        endpoint = os.environ.get("LIBRECHAT_ENDPOINT", "openAI")
        BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        def login():
            resp = requests.post(
                f"{base_url}/api/auth/login",
                json={"email": os.environ["LIBRECHAT_EMAIL"], "password": os.environ["LIBRECHAT_PASSWORD"]},
                timeout=15,
            )
            resp.raise_for_status()
            return resp.json()["token"]

  - title: Run It & Test
    description: "Send one message, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        jwt_token = login()
        headers = {"Authorization": f"Bearer {jwt_token}", "Content-Type": "application/json", "User-Agent": BROWSER_UA}

        with tracer.start_as_current_span("librechat.chat") as span:
            span.set_attribute("librechat.endpoint", endpoint)
            resp = requests.post(
                f"{base_url}/api/agents/chat",
                headers=headers,
                json={"text": "What is distributed tracing?", "endpoint": endpoint, "model": "gpt-4o-mini"},
                timeout=30,
            )
            resp.raise_for_status()
            span.set_attribute("librechat.conversation_id", resp.json()["conversationId"])
            span.set_attribute("librechat.status_code", resp.status_code)

        openobserve_shutdown()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = librechat.chat`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - librechat_endpoint
      - librechat_conversation_id
      - librechat_status_code

extras:
  installs:
    - openobserve-telemetry-sdk
    - opentelemetry-api
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Send A Browser User-Agent"
fix_body: "If requests are rejected with `Illegal request`, LibreChat is blocking a non-browser User-Agent. Add a browser UA header to the chat call:"
fix_snippet: |
  BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  headers = {"Authorization": f"Bearer {jwt_token}", "User-Agent": BROWSER_UA}

troubleshooting:
  - q: "Requests rejected with Illegal request"
    a: "LibreChat enforces a browser User-Agent on the chat endpoint. Send a Chrome-like User-Agent header with every request."
  - q: "App runs but no spans appear"
    a: "Move openobserve_init() to the top, ensure each message is wrapped in tracer.start_as_current_span(), and call openobserve_shutdown() so spans flush."
  - q: "Login fails with 401"
    a: "Check LIBRECHAT_EMAIL / LIBRECHAT_PASSWORD and that LIBRECHAT_BASE_URL points at your running instance."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# LibreChat

Trace LibreChat API messages to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
