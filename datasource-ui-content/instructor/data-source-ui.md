---
# Rich, stepped setup card for the OpenObserve Data Sources panel.
card:
  name: Instructor
  tagline: "Trace Instructor structured-output extractions, retries, token usage, and the underlying LLM calls."
  runtime: Python 3.9+
  setup_time: ~3 min

detect:
  stream_type: traces
  stream: default
  # Instructor extraction TOOL spans store operation_name as instructor.patch.
  filter: "operation_name = 'instructor.patch'"
  model_label: gpt-4o-mini

doc_url: https://openobserve.ai/docs/integration/ai/frameworks/instructor/
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
        # your model provider key
        OPENAI_API_KEY=your-openai-key

  - title: Install & Instrument
    description: "Install the SDK + both instrumentors, then call `InstructorInstrumentor().instrument()` and `OpenAIInstrumentor().instrument()` **before** importing Instructor or the OpenAI client. Full details in the docs."
    chip: { kind: editor, label: main.py }
    required: true
    complete_on: copy
    note: "Instrument both layers: the Instructor instrumentor captures the extraction span, the OpenAI instrumentor captures the raw LLM call beneath it."
    code:
      lang: python
      filename: main.py
      text: |
        # pip install openobserve-telemetry-sdk openinference-instrumentation-instructor openinference-instrumentation-openai instructor openai python-dotenv
        from dotenv import load_dotenv
        load_dotenv()

        from openinference.instrumentation.instructor import InstructorInstrumentor
        from openinference.instrumentation.openai import OpenAIInstrumentor
        from openobserve import openobserve_init

        InstructorInstrumentor().instrument()
        OpenAIInstrumentor().instrument()
        openobserve_init()

  - title: Run Your App & Test
    description: "Make a structured extraction, then click **Test** to detect the first span:"
    chip: { kind: run, label: Run }
    complete_on: detect
    detection_anchor: true
    code:
      lang: python
      filename: main.py
      text: |
        import instructor
        from openai import OpenAI
        from pydantic import BaseModel

        class Person(BaseModel):
            name: str
            age: int
            occupation: str

        client = instructor.from_openai(OpenAI())

        person = client.chat.completions.create(
            model="gpt-4o-mini",
            response_model=Person,
            messages=[{"role": "user", "content": "Marie Curie was a 44-year-old physicist."}],
        )
        print(f"{person.name}, age {person.age}, {person.occupation}")

  - title: Check OpenObserve
    description: "Open **Traces** and filter `operation_name = instructor.patch`. Each extraction produces a TOOL span with a child OpenAI LLM span carrying:"
    chip: { kind: traces, label: Traces }
    complete_on: detect
    pills:
      - llm_model_name
      - llm_request_parameters_response_model
      - llm_usage_tokens_input

extras:
  installs:
    - openobserve-telemetry-sdk
    - openinference-instrumentation-instructor
    - openinference-instrumentation-openai
    - instructor
    - openai
    - python-dotenv
  env_vars:
    - OPENOBSERVE_URL
    - OPENOBSERVE_ORG
    - OPENOBSERVE_AUTH_TOKEN

fix_title: "Instrument Before Importing Instructor"
fix_body: "If your app runs but no spans appear, instrumentation loaded too late. Re-order so both instrumentors run first:"
fix_snippet: |
  # instrument FIRST — before importing instructor or openai
  InstructorInstrumentor().instrument()
  OpenAIInstrumentor().instrument()
  openobserve_init()

  # only then import and use instructor
  import instructor

troubleshooting:
  - q: "App runs but no spans appear"
    a: "Move both InstructorInstrumentor().instrument() and OpenAIInstrumentor().instrument() above any instructor or openai import."
  - q: "Extraction spans appear but no child LLM spans"
    a: "You forgot the OpenAI instrumentor. Call OpenAIInstrumentor().instrument() alongside InstructorInstrumentor()."
  - q: "pip complains about an externally-managed environment"
    a: "Re-run pip with --break-system-packages --user, or install inside a virtualenv."
  - q: "Auth errors in the OpenObserve logs"
    a: "OPENOBSERVE_AUTH_TOKEN must be `Basic <base64>`. Re-copy it from Manage Tokens."

---

# Instructor

Trace Instructor structured-output extractions and the underlying LLM calls to
OpenObserve via OpenTelemetry. The Data Sources panel renders the stepped setup
card from the frontmatter above; this body is human-readable notes only.
