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
