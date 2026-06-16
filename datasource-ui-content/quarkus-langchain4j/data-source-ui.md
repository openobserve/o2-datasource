---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Quarkus LangChain4j
  tagline: "Trace Quarkus AI service calls: token usage, cost, prompts, and model metadata."
  runtime: Java 17+ / Maven
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # The doc sets quarkus.otel.service.name=quarkus-langchain4j, which OpenObserve
  # stores as service_name on every span.
  filter: "service_name = 'quarkus-langchain4j'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/quarkus-langchain4j/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Set your OpenObserve OTLP endpoint, headers, and OpenAI key. Quarkus reads these from `application.properties`; the values below mirror that config."
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
        # used in application.properties:
        #   quarkus.otel.exporter.otlp.endpoint={url}/api/{org}
        #   quarkus.otel.exporter.otlp.headers=Authorization=Basic {token}
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Add the OpenTelemetry + LangChain4j dependencies to `pom.xml`, configure `application.properties`, and define an `@RegisterAiService`. Full details in the docs."
    chip: { kind: editor, label: application.properties }
    required: true
    complete_on: copy
    note: "Set quarkus.otel.exporter.otlp.protocol=http/protobuf and the endpoint to {url}/api/{org}. Enable include-prompt / include-completion to capture prompt and response text."
    code:
      lang: properties
      filename: application.properties
      text: |
        # pom.xml deps: io.quarkiverse.langchain4j:quarkus-langchain4j-openai
        #               io.quarkus:quarkus-opentelemetry
        quarkus.application.name=quarkus-langchain4j
        quarkus.otel.service.name=quarkus-langchain4j

        quarkus.otel.exporter.otlp.protocol=http/protobuf
        quarkus.otel.exporter.otlp.endpoint={url}/api/{org}
        quarkus.otel.exporter.otlp.headers=Authorization=Basic {token}

        quarkus.langchain4j.openai.api-key=${OPENAI_API_KEY}
        quarkus.langchain4j.openai.chat-model.model-name=gpt-4o-mini
        quarkus.langchain4j.openai.timeout=30s

        quarkus.langchain4j.tracing.include-prompt=true
        quarkus.langchain4j.tracing.include-completion=true

  - title: Run Your App & Test
    description: "Build, run, and invoke your AI service, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    note: "In command mode, wrap the AI service call in an @ApplicationScoped runner annotated with @ActivateRequestContext so the CDI request scope is active."
    code:
      lang: bash
      filename: run.sh
      text: |
        # @RegisterAiService interface AiService { String ask(@UserMessage String q); }
        mvn package
        export OPENAI_API_KEY=your-key
        java -jar target/quarkus-app/quarkus-run.jar

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = quarkus-langchain4j`. Each AI service call produces a root span plus a child `completion` span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_request_model
      - gen_ai_usage_prompt_tokens
      - gen_ai_client_estimated_cost

extras:
  installs:
    - quarkus-langchain4j-openai
    - quarkus-opentelemetry
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - OPENAI_API_KEY

fix_title: "Check the OTLP Endpoint and Request Scope"
fix_body: "If your app runs but no spans appear, the OTLP exporter is misconfigured or the CDI request scope is inactive. Verify the endpoint and wrap the call:"
fix_lang: properties
fix_snippet: |
  # endpoint must point at /api/<org> with the protobuf protocol
  quarkus.otel.exporter.otlp.protocol=http/protobuf
  quarkus.otel.exporter.otlp.endpoint=<your-openobserve-url>/api/<your-org>
  # and in command mode, annotate the runner bean with @ActivateRequestContext

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Confirm quarkus-opentelemetry is on the classpath and the OTLP endpoint is {url}/api/{org} with protocol http/protobuf. In command mode, wrap the AI call in an @ActivateRequestContext runner."
  - q: "Spans appear but the filter matches nothing"
    a: "The filter matches quarkus.otel.service.name. If you changed it, update the service_name value in the filter accordingly."
  - q: "Prompt and completion text are missing"
    a: "Set quarkus.langchain4j.tracing.include-prompt=true and include-completion=true in application.properties."
  - q: "Auth errors in the OpenObserve logs"
    a: "The Authorization header must be `Basic <base64>`. Re-copy the token from Manage Tokens."

---

# Quarkus LangChain4j

Trace Quarkus LangChain4j AI service calls to OpenObserve via the native
quarkus-opentelemetry extension and OTLP. The Data Sources panel renders the
stepped setup card from the frontmatter above.
