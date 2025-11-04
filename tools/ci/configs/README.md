# CI Configuration Files

## Overview

These configuration files control the behavior of the Azure DevOps pipeline for sample generation, validation, and publishing. Each file defines a set of variables that enable or disable different pipeline stages and configure their behavior.

## How to Use

Configuration files are selected via the **CIConfigInput** parameter when running the pipeline in Azure DevOps. This appears as a dropdown in the pipeline UI.

## Variables Reference

### Pipeline Stage Controls

These boolean variables control which stages of the pipeline are executed:

- **`runGenerateSamples`**: (`true`/`false`)  
  Enables the **GenerateSamples** stage that uses Caleuche CLI to generate code samples from templates.

- **`runValidateSamples`**: (`true`/`false`)  
  Enables the **ValidateSamples** stage that compiles and optionally runs samples to ensure they work correctly.

- **`runPublishSamples`**: (`true`/`false`)  
  Enables the **PublishSamples** stage that publishes validated samples to configured destinations.

### Publishing Options

These variables control where and how samples are published (only used when `runPublishSamples: true`):

- **`publishSampleLibrary`**: (`true`/`false`)  
  When enabled, packages validated samples as an npm package and publishes to Azure Artifacts feed.  
  Package: `@azure-foundry/sample-library`

- **`publishToGitHub`**: (`true`/`false`)  
  When enabled, commits validated samples to a new branch in the GitHub repository.  
  Branch format: `ci/publish-samples-<BuildId>`

### Sample Generation

- **`templateConfig`**: (string)  
  Specifies which sample configuration file to use for generation.  
  Examples: `default-samples.yaml`, `foundry-samples.yaml`  
  Path: `tools/sample-configs/<templateConfig>`

### Validation Behavior

- **`VALIDATE_WITH_SERVICE`**: (`true`/`false`)  
  When `true`, samples are executed against live Azure OpenAI services during validation.  
  When `false`, only compilation/build verification is performed.  
  ⚠️ Requires Azure credentials to be configured.

## Creating New Configurations

To create a new configuration profile:

1. Create a new YAML file in `tools/ci/configs/`
2. Define required variables based on your needs
3. Add the filename to the `parameters.values` list in `azure-pipelines.yml`:

```yaml
parameters:
  - name: CIConfigInput
    values:
      - 'default.yaml'
      - 'foundry-ux.yaml'
      - 'your-new-config.yaml'  # Add here
```

## Common Scenarios

### Validate Only (No Service Calls)
```yaml
variables:
  runGenerateSamples: true
  runValidateSamples: true
  runPublishSamples: false
  VALIDATE_WITH_SERVICE: false
```

### Full CI/CD with Service Testing
```yaml
variables:
  runGenerateSamples: true
  runValidateSamples: true
  runPublishSamples: true
  VALIDATE_WITH_SERVICE: true
  publishSampleLibrary: true
  # Azure credentials required
```

### Skip Generation (Use Existing Samples)
```yaml
variables:
  runGenerateSamples: false
  runValidateSamples: true
  runPublishSamples: false
```
