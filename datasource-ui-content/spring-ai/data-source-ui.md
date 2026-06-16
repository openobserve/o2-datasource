---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Spring AI
  tagline: "Trace Spring AI ChatClient calls: model, token usage, and request params."
  runtime: Java 17+ / Maven
  setup_time: ~5 min

detect:
  stream_type: traces
  stream: default
  # The doc sets spring.application.name=spring-ai, which becomes service_name on
  # every span in OpenObserve.
  filter: "service_name = 'spring-ai'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/spring-ai/
slack_url: https://short.openobserve.ai/community

steps:
  - title: Set Environment Variables
    description: "Set your OpenObserve OTLP endpoint, auth header, and OpenAI key. Spring reads these from `application.yml`; the values below mirror that config."
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
        # used in application.yml:
        #   management.otlp.tracing.endpoint={url}/api/{org}/v1/traces
        #   management.otlp.tracing.headers.Authorization=Basic {token}
        OPENAI_API_KEY=your-openai-api-key

  - title: Install & Instrument
    description: "Add the Micrometer + OTLP exporter dependencies to `pom.xml`, then configure tracing in `application.yml`. ChatClient calls are traced automatically. Full details in the docs."
    chip: { kind: editor, label: application.yml }
    required: true
    complete_on: copy
    note: "spring.application.name becomes service_name in OpenObserve. Set sampling probability to 1.0 to capture every call while testing."
    code:
      lang: yaml
      filename: application.yml
      text: |
        # pom.xml deps: spring-ai-starter-model-openai, spring-boot-starter-actuator,
        #               micrometer-tracing-bridge-otel, opentelemetry-exporter-otlp
        spring:
          main:
            web-application-type: none
          application:
            name: spring-ai
          ai:
            openai:
              api-key: ${OPENAI_API_KEY}
              chat:
                options:
                  model: gpt-4o-mini
                  max-tokens: 256

        management:
          tracing:
            sampling:
              probability: 1.0
          otlp:
            tracing:
              endpoint: ${OPENOBSERVE_OTLP_URL:{url}/api/{org}/v1/traces}
              headers:
                Authorization: ${OPENOBSERVE_AUTH_TOKEN:Basic {token}}

  - title: Run Your App & Test
    description: "Make any ChatClient call, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: bash
      filename: run.sh
      text: |
        # In a CommandLineRunner bean:
        #   ChatClient client = builder.build();
        #   client.prompt("What is distributed tracing?").call().content();
        export OPENAI_API_KEY=your-key
        mvn spring-boot:run

  - title: Check OpenObserve
    description: "Open **Traces** and filter `service_name = spring-ai`. Expand a trace to the innermost `chat` span, which carries:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - gen_ai_request_model
      - gen_ai_usage_input_tokens
      - gen_ai_usage_output_tokens

extras:
  installs:
    - spring-ai-starter-model-openai
    - micrometer-tracing-bridge-otel
    - opentelemetry-exporter-otlp
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN
    - OPENAI_API_KEY

fix_title: "Check the OTLP Endpoint and Sampling"
fix_body: "If your app runs but no spans appear, the exporter endpoint is wrong or sampling is off. Verify the config:"
fix_lang: yaml
fix_snippet: |
  management:
    tracing:
      sampling:
        probability: 1.0
    otlp:
      tracing:
        endpoint: <your-openobserve-url>/api/<your-org>/v1/traces

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Confirm micrometer-tracing-bridge-otel and opentelemetry-exporter-otlp are on the classpath, sampling probability is 1.0, and the OTLP endpoint ends in /api/<org>/v1/traces."
  - q: "Spans appear but the filter matches nothing"
    a: "The filter matches spring.application.name. If you changed it, update the service_name value in the filter accordingly."
  - q: "The process exits before spans flush"
    a: "For command-line apps, call System.exit(0) only after the ChatClient call returns so the exporter can flush."
  - q: "Auth errors in the OpenObserve logs"
    a: "The Authorization header must be `Basic <base64>`. Re-copy the token from Manage Tokens."

---

# Spring AI

Trace Spring AI ChatClient calls to OpenObserve via Micrometer Tracing and OTLP.
Every call is traced automatically with a full span hierarchy. The Data Sources
panel renders the stepped setup card from the frontmatter above.
