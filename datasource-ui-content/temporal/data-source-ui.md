---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Temporal
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace Temporal durable workflows: workflow starts, runs, and activity executions."
  runtime: Python 3.9+
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. Temporal's TracingInterceptor emits spans
  # whose operation_name starts with StartWorkflow:/RunWorkflow:/ExecuteActivity:.
  filter: "operation_name LIKE 'StartWorkflow:%'"

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/temporal/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials and Temporal host."
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
        TEMPORAL_HOST=localhost:7233

  - title: Install & Instrument
    description: "Install temporalio + the OTLP exporter, configure a TracerProvider, and pass `TracingInterceptor` to both the client and worker. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Keep the OTel setup and asyncio.run() inside main() / under __main__. Temporal's workflow sandbox re-executes the module, so top-level side effects will error. Start a dev server first: temporal server start-dev --port 7233 --headless"
    code:
      lang: python
      filename: main.py
      text: |
        # pip install temporalio opentelemetry-sdk opentelemetry-exporter-otlp-proto-http python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        import os, asyncio
        from datetime import timedelta
        from temporalio import activity, workflow
        from temporalio.client import Client
        from temporalio.worker import Worker
        from temporalio.worker.workflow_sandbox import SandboxedWorkflowRunner, SandboxRestrictions
        from temporalio.contrib.opentelemetry import TracingInterceptor

        @activity.defn
        async def process(text: str) -> str:
            return f"Processed: {text[:30]}"

        @workflow.defn
        class TextWorkflow:
            @workflow.run
            async def run(self, text: str) -> str:
                return await workflow.execute_activity(
                    process, text, start_to_close_timeout=timedelta(seconds=10)
                )

        async def main():
            from opentelemetry import trace
            from opentelemetry.sdk.trace import TracerProvider
            from opentelemetry.sdk.trace.export import BatchSpanProcessor
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

            endpoint = os.environ["OPENOBSERVE_URL"].rstrip("/") + "/api/" + os.environ["OPENOBSERVE_ORG"] + "/v1/traces"
            provider = TracerProvider()
            provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(
                endpoint=endpoint,
                headers={"Authorization": os.environ["OPENOBSERVE_AUTH_TOKEN"]},
            )))
            trace.set_tracer_provider(provider)

            client = await Client.connect(
                os.environ.get("TEMPORAL_HOST", "localhost:7233"),
                interceptors=[TracingInterceptor()],
            )
            return client, provider

  - title: Run Your App & Test
    description: "Run a workflow through a worker, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        async def run_workflow():
            client, provider = await main()
            sandbox = SandboxedWorkflowRunner(
                restrictions=SandboxRestrictions.default.with_passthrough_modules(
                    "opentelemetry", "requests", "urllib3"
                )
            )
            async with Worker(
                client, task_queue="oo-queue",
                workflows=[TextWorkflow], activities=[process],
                interceptors=[TracingInterceptor()], workflow_runner=sandbox,
            ):
                result = await client.execute_workflow(
                    TextWorkflow.run, "Explain distributed tracing.",
                    id="oo-test-1", task_queue="oo-queue",
                )
                print(result)
            provider.shutdown()

        if __name__ == "__main__":
            asyncio.run(run_workflow())

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name LIKE 'StartWorkflow:%'`. Workflow and activity spans carry:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - temporalworkflowid
      - span_kind
      - span_status

extras:
  installs:
    - temporalio
    - opentelemetry-sdk
    - opentelemetry-exporter-otlp-proto-http
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - TEMPORAL_HOST

fix_title: "Keep OTel Setup Inside main()"
fix_body: "If the worker errors on import or no spans appear, OTel setup ran at module top level. Move it inside main() and flush before exit:"
fix_snippet: |
  # configure the provider inside main(), not at module top level
  async def main():
      trace.set_tracer_provider(provider)
      # ... connect client + run worker with TracingInterceptor ...

  # flush before the process exits
  provider.shutdown()

troubleshooting:
  - q: "Worker errors during initialization"
    a: "Temporal's sandbox re-executes the module. Keep all OTel setup and asyncio.run() inside main() or under if __name__ == '__main__', and pass the modules via with_passthrough_modules."
  - q: "Spans appear but the filter matches nothing"
    a: "Operation names look like StartWorkflow:TextWorkflow / RunWorkflow:... / ExecuteActivity:... Open Traces and adjust the LIKE pattern to match your workflow type."
  - q: "No spans appear at all"
    a: "Confirm the Temporal dev server is running on TEMPORAL_HOST and TracingInterceptor is passed to BOTH the client and the worker."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Temporal

Trace Temporal durable workflow executions to OpenObserve via OpenTelemetry using
the built-in TracingInterceptor. The Data Sources panel renders the stepped setup
card from the frontmatter above.
