---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: OpenAI (JS/TS)
  tagline: "Trace OpenAI SDK calls from Node.js: latency, token usage, model name, and finish reason."
  runtime: Node.js 18+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # best-effort; confirm on ingest. The OpenInference OpenAI instrumentor sets
  # operation_name='OpenAI Chat Completions' and llm_system='openai'.
  filter: "operation_name = 'OpenAI Chat Completions'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/providers/openai-js/
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
        OTEL_EXPORTER_OTLP_ENDPOINT={url}/api/{org}/v1/traces
        OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic {token}

  - title: Install & Instrument
    description: "Install the SDK + OpenInference instrumentor, then start the OTel SDK **before** `require()`-ing the OpenAI SDK so the patch applies."
    chip: { kind: editor, label: index.js }
    required: true
    complete_on: copy
    note: "The instrumentation patches the module at require() time, so OpenAI must be imported after sdk.start()."
    code:
      lang: javascript
      filename: index.js
      text: |
        // npm install openai @arizeai/openinference-instrumentation-openai \
        //   @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-http \
        //   @opentelemetry/sdk-trace-base @opentelemetry/resources dotenv
        require('dotenv').config();

        const { NodeSDK } = require('@opentelemetry/sdk-node');
        const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
        const { SimpleSpanProcessor } = require('@opentelemetry/sdk-trace-base');
        const { resourceFromAttributes } = require('@opentelemetry/resources');
        const { OpenAIInstrumentation } = require('@arizeai/openinference-instrumentation-openai');

        const authHeader = process.env.OTEL_EXPORTER_OTLP_HEADERS.replace('Authorization=', '');

        const sdk = new NodeSDK({
          resource: resourceFromAttributes({ 'service.name': 'my-openai-app' }),
          spanProcessors: [
            new SimpleSpanProcessor(
              new OTLPTraceExporter({
                url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT,
                headers: { Authorization: authHeader },
              })
            ),
          ],
          instrumentations: [new OpenAIInstrumentation()],
        });
        sdk.start();

        // require() AFTER sdk.start() so the instrumentation patch applies
        const OpenAI = require('openai');

  - title: Run Your App & Test
    description: "Make any OpenAI call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: javascript
      filename: index.js
      text: |
        async function main() {
          const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
          const response = await client.chat.completions.create({
            model: 'gpt-4o-mini',
            messages: [{ role: 'user', content: 'What is distributed tracing?' }],
            max_tokens: 256,
          });
          console.log(response.choices[0].message.content);
          await sdk.shutdown();
        }
        main().catch(console.error);

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = OpenAI Chat Completions`. Each span carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_token_count_prompt
      - llm_finish_reason

extras:
  installs:
    - openai
    - "@arizeai/openinference-instrumentation-openai"
    - "@opentelemetry/sdk-node"
    - "@opentelemetry/exporter-trace-otlp-http"
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - OPENAI_API_KEY

fix_title: "Require The OpenAI SDK After sdk.start()"
fix_body: "If your app runs but no spans appear, the SDK was loaded before instrumentation patched it. Re-order so sdk.start() runs first:"
fix_lang: javascript
fix_snippet: |
  // start the OTel SDK FIRST
  sdk.start();
  // only THEN require the OpenAI SDK
  const OpenAI = require('openai');

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move the `require('openai')` call below `sdk.start()`. The patch only applies to modules loaded after the SDK starts."
  - q: "Spans appear but the filter matches nothing"
    a: "Open Traces and confirm the stored attribute — spans set operation_name='OpenAI Chat Completions' and llm_system='openai'. Adjust the filter to match."
  - q: "Process exits before traces flush"
    a: "Call `await sdk.shutdown()` before the process ends so buffered spans are exported."
  - q: "Auth errors in the OpenObserve logs"
    a: "OTEL_EXPORTER_OTLP_HEADERS must be `Authorization=Basic <base64>`. Re-copy the token from Manage Tokens."

---

# OpenAI (JS/TS)

Trace OpenAI JS/TS SDK calls to OpenObserve via OpenTelemetry. The Data Sources
panel renders the stepped setup card from the frontmatter above; this body is
human-readable notes only.
