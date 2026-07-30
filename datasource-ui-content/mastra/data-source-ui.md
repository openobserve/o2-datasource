---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Mastra
  logo: logo.svg
  logo_dark: dark-logo.svg
  tagline: "Trace Mastra agent runs with latency, token usage, model name, and finish reason from TypeScript."
  runtime: Node.js 18+
  setup_time: ~4 min

detect:
  stream_type: traces
  stream: default
  # The instrumentation wraps each agent.generate() in a manual span named
  # mastra.agent_run, stored as operation_name.
  filter: "operation_name = 'mastra.agent_run'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/mastra/
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
    description: "Install Mastra + the OTel SDK, then set up the `NodeSDK` with an OTLP exporter **before** importing Mastra (use dynamic imports). Wrap each `agent.generate()` in a manual span. Full details in the docs."
    chip: { kind: editor, label: app.mjs }
    required: true
    complete_on: copy
    note: "Point the OTLP exporter at ${OPENOBSERVE_URL}api/${OPENOBSERVE_ORG}/v1/traces with the Authorization header set to your Basic token. Use dynamic imports so the SDK starts before Mastra loads."
    code:
      lang: javascript
      filename: app.mjs
      text: |
        // npm install @mastra/core @ai-sdk/openai @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-http @opentelemetry/sdk-trace-base @opentelemetry/resources @opentelemetry/api dotenv
        import 'dotenv/config';
        process.env.OTEL_SERVICE_NAME = 'my-mastra-app';

        import { NodeSDK } from '@opentelemetry/sdk-node';
        import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
        import { SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
        import { resourceFromAttributes } from '@opentelemetry/resources';

        const sdk = new NodeSDK({
          resource: resourceFromAttributes({ 'service.name': 'my-mastra-app' }),
          spanProcessors: [
            new SimpleSpanProcessor(new OTLPTraceExporter({
              url: `${process.env.OPENOBSERVE_URL}api/${process.env.OPENOBSERVE_ORG}/v1/traces`,
              headers: { Authorization: process.env.OPENOBSERVE_AUTH_TOKEN },
            })),
          ],
        });
        sdk.start();

  - title: Run Your App & Test
    description: "Run an agent inside a manual span, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: javascript
      filename: app.mjs
      text: |
        const { trace, SpanStatusCode } = await import('@opentelemetry/api');
        const { Agent } = await import('@mastra/core/agent');
        const { openai } = await import('@ai-sdk/openai');

        const tracer = trace.getTracer('mastra-agent');
        const agent = new Agent({
          name: 'my-assistant',
          instructions: 'You are a helpful assistant.',
          model: openai('gpt-4o-mini'),
        });

        await tracer.startActiveSpan('mastra.agent_run', async (span) => {
          span.setAttributes({ agent_name: agent.name, ai_model_name: 'gpt-4o-mini' });
          const result = await agent.generate('What is distributed tracing?');
          span.setAttributes({
            ai_usage_input_tokens: result.usage?.inputTokens || 0,
            ai_usage_output_tokens: result.usage?.outputTokens || 0,
            ai_finish_reason: result.finishReason || '',
          });
          span.setStatus({ code: SpanStatusCode.OK });
          console.log(result.text);
          span.end();
        });
        await sdk.shutdown();

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = mastra.agent_run`. Each agent run carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - ai_model_name
      - ai_usage_input_tokens
      - ai_finish_reason

extras:
  installs:
    - "@mastra/core"
    - "@ai-sdk/openai"
    - "@opentelemetry/sdk-node"
    - "@opentelemetry/exporter-trace-otlp-http"
    - dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_lang: javascript
fix_title: "Start the OTel SDK Before Importing Mastra"
fix_body: "If your app runs but no spans appear, the SDK started after Mastra loaded. Start it first and use dynamic imports for Mastra:"
fix_snippet: |
  // start the SDK FIRST
  sdk.start();

  // then dynamically import Mastra so it picks up the active provider
  const { Agent } = await import('@mastra/core/agent');

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call sdk.start() before any dynamic import of @mastra/core, and await sdk.shutdown() before the process exits."
  - q: "401/403 from the OTLP endpoint"
    a: "The Authorization header must be the full `Basic <base64>` value. Re-copy OPENOBSERVE_AUTH_TOKEN from Manage Tokens."
  - q: "Wrong endpoint path"
    a: "The exporter URL must be ${OPENOBSERVE_URL}api/${OPENOBSERVE_ORG}/v1/traces."
  - q: "npm install fails on @opentelemetry packages"
    a: "Use Node.js 18+ and ensure all @opentelemetry/* versions are compatible (install them together)."

---

# Mastra

Trace Mastra agent runs to OpenObserve via OpenTelemetry. The Data Sources panel
renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
