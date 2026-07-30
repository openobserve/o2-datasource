---
# codename-goose/data-source-ui.md
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Codename Goose
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace Codename Goose CLI sessions: run latency, exit codes, and output lengths."
  runtime: Python 3.8+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Each goose run is wrapped in a manual span
  # named goose.session_run, which OpenObserve maps to operation_name.
  filter: "operation_name = 'goose.session_run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/no-code/codename-goose/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and your provider key."
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
        GOOSE_PROVIDER=openai
        GOOSE_MODEL=gpt-4o-mini

  - title: Install Goose & Wrap The Subprocess
    description: "Install the Goose CLI, install the Python deps, then init OpenObserve and wrap each `goose run` call in a manual span."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Install the CLI first: curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | bash"
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve opentelemetry-api requests python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openobserve import openobserve_init
        openobserve_init()

        from opentelemetry import trace
        import os, subprocess

        tracer = trace.get_tracer(__name__)
        goose_env = {**os.environ, "GOOSE_PROVIDER": "openai", "GOOSE_MODEL": "gpt-4o-mini"}

        def run_goose(prompt: str):
            with tracer.start_as_current_span("goose.session_run") as span:
                span.set_attribute("goose.prompt", prompt[:100])
                span.set_attribute("goose.provider", "openai")
                span.set_attribute("goose.model", "gpt-4o-mini")
                result = subprocess.run(
                    ["goose", "run", "-t", prompt, "-q"],
                    capture_output=True, text=True, timeout=60, env=goose_env,
                )
                span.set_attribute("goose.exit_code", result.returncode)
                span.set_attribute("goose.output_length", len(result.stdout))
                span.set_attribute("span_status", "OK" if result.returncode == 0 else "ERROR")
                return result.stdout.strip()

  - title: Run It & Test
    description: "Run a session, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        output = run_goose("Explain distributed tracing in one sentence.")
        print(output)

        trace.get_tracer_provider().force_flush()

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = goose.session_run`. Each session produces a span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - goose_model
      - goose_exit_code
      - goose_output_length

extras:
  installs:
    - openobserve
    - opentelemetry-api
    - requests
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Init Before The First Session & Flush At The End"
fix_body: "If your app runs but no spans appear, init too late or never flushed. Call init first and force_flush before exit:"
fix_snippet: |
  # init FIRST, before running any session
  openobserve_init()
  tracer = trace.get_tracer(__name__)

  # ... wrap goose run in tracer.start_as_current_span("goose.session_run") ...

  # flush before the process exits so spans are exported
  trace.get_tracer_provider().force_flush()

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call openobserve_init() before running any session, and trace.get_tracer_provider().force_flush() before the process exits."
  - q: "goose: command not found"
    a: "Install the CLI first via the download_cli.sh script, then ensure ~/.local/bin (or wherever it installed) is on your PATH."
  - q: "Session times out or exits non-zero"
    a: "Check GOOSE_PROVIDER / GOOSE_MODEL and your provider API key. Filter goose_exit_code != 0 in Traces to inspect failed runs."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Codename Goose

Trace Codename Goose CLI sessions to OpenObserve via OpenTelemetry. Goose is
Block's open-source AI developer agent; this integration wraps `goose run`
subprocess calls in manual spans. The Data Sources panel renders the stepped
setup card from the frontmatter above; this body is human-readable notes only.
