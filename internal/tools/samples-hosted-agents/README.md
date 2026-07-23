# samples-hosted-agents

Test payload files (`test-payload.txt`) used by the hosted-agents cloud E2E pipeline
(`.github/workflows/hosted-agents-cloud-e2e.yml`) to invoke each sample agent.

Layout mirrors the sample directories by language, protocol, and sample name:

```
samples-hosted-agents/
  <language>/        # python | csharp
    <protocol>/      # invocations | responses
      <sample-name>/
        test-payload.txt
```

Each `test-payload.txt` contains one prompt per line (plain string or JSON).
Each line is sent to `azd ai agent invoke` as a separate turn. If a sample has
no payload file here, the pipeline falls back to a default 3-turn payload.

A sample can optionally add `test-assertions.yml` beside its payload. The
assertions run only when all conditions under `when` match the matrix cell.
Supported assertion sources are:

- `response` — `/tmp/invoke-out-<turn>.txt`; requires a positive `turn`.
- `console_log` — combined console and system monitor output for the hosted
  session. When only log-dependent assertions are missing, the runner retries
  bounded retrieval after 30 and 60 seconds because fresh session logs are
  eventually consistent.

Every assertion requires a Python regular expression in `regex` and can set
`min_matches` (default `1`). Unknown fields and malformed assertions fail the
cell rather than being ignored. Example:

```yaml
when:
  toolbox_label: code-interpreter

assertions:
  - source: response
    turn: 1
    regex: '(?<![0-9])70,?512(?![0-9])'
  - source: console_log
    regex: "Tool 'code_interpreter' returned [1-9][0-9]* chars"
    min_matches: 1
```
