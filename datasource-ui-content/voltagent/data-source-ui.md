---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: VoltAgent
  logo: logo.png
  tagline: "Trace VoltAgent runs: model, token usage, user ID, and session ID."
  runtime: Node.js 18+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. VoltAgent emits a span per agent call whose
  # operation_name is generateText.
  filter: "operation_name = 'generateText'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/voltagent/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Create a `.env` in your project root with your OpenObserve credentials."
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
    description: "Install VoltAgent + OTel packages, set up the OTLP exporter **before** requiring VoltAgent. Full details in the docs."
    chip: { kind: editor, label: index.js }
    required: true
    complete_on: copy
    note: "Call sdk.start() before requiring @voltagent/core — VoltAgent reads the active tracer provider and emits spans automatically. await sdk.shutdown() before exit to flush."
    code:
      lang: javascript
      filename: index.js
      text: |
        // npm install @voltagent/core @voltagent/vercel-ai "@ai-sdk/openai@^2" \
        //   @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-http \
        //   @opentelemetry/sdk-trace-base @opentelemetry/resources dotenv
        process.env.OTEL_SERVICE_NAME = 'voltagent-app';
        require('dotenv').config();

        const { NodeSDK } = require('@opentelemetry/sdk-node');
        const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
        const { SimpleSpanProcessor } = require('@opentelemetry/sdk-trace-base');
        const { resourceFromAttributes } = require('@opentelemetry/resources');

        const sdk = new NodeSDK({
          resource: resourceFromAttributes({ 'service.name': 'voltagent-app' }),
          spanProcessors: [
            new SimpleSpanProcessor(
              new OTLPTraceExporter({
                url: `${process.env.OPENOBSERVE_URL}api/${process.env.OPENOBSERVE_ORG}/v1/traces`,
                headers: { Authorization: process.env.OPENOBSERVE_AUTH_TOKEN },
              })
            ),
          ],
        });
        sdk.start();

        const { Agent } = require('@voltagent/core');
        const { VercelAIProvider } = require('@voltagent/vercel-ai');
        const { openai } = require('@ai-sdk/openai');

  - title: Run Your App & Test
    description: "Make any agent call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: javascript
      filename: index.js
      text: |
        async function main() {
          const agent = new Agent({
            name: 'observability-agent',
            description: 'Answers questions about observability.',
            llm: new VercelAIProvider(),
            model: openai('gpt-4o-mini'),
          });

          const result = await agent.generateText(
            'Explain distributed tracing in one sentence.',
            { userId: 'user-123' }
          );
          console.log(result);
          await sdk.shutdown();
        }

        main().catch(console.error);

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = generateText`. Each agent call carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - agent_name
      - ai_model_name
      - enduser_id

extras:
  installs:
    - "@voltagent/core"
    - "@voltagent/vercel-ai"
    - "@opentelemetry/sdk-node"
    - "@opentelemetry/exporter-trace-otlp-http"
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Start the SDK Before Requiring VoltAgent"
fix_body: "If your app runs but no spans appear, the OTel SDK started too late. Re-order so it runs first:"
fix_lang: javascript
fix_snippet: |
  // start the SDK FIRST — before requiring VoltAgent
  sdk.start();

  // only then require and use VoltAgent
  const { Agent } = require('@voltagent/core');

  // flush before the process exits
  await sdk.shutdown();

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Call sdk.start() before requiring @voltagent/core, and await sdk.shutdown() before exiting so spans flush."
  - q: "Spans appear but the filter matches nothing"
    a: "VoltAgent uses operation_name = generateText. Open Traces, confirm the operation_name, and adjust the filter if needed."
  - q: "Export fails with a 401"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."
  - q: "Endpoint not found / 404"
    a: "Confirm OPENOBSERVE_URL ends with a slash so the URL resolves to {url}/api/{org}/v1/traces."

---

# VoltAgent

Trace VoltAgent runs to OpenObserve via OpenTelemetry. VoltAgent has built-in
OTel support and emits generateText spans automatically once the OTLP exporter is
configured. The Data Sources panel renders the stepped setup card from the frontmatter.
