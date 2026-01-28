# Foundry Template Samples

A comprehensive collection of code templates and generated samples for Foundry client library and SDK implementations across multiple programming languages. This repository provides a robust pipeline for generating, validating, and maintaining consistent code samples for Foundry services.

## 🚀 Overview

This repository serves as the hub for Foundry code sample templates that automatically generate language-specific implementations. Using the [Caleuche CLI tool](https://github.com/brandor64/caleuche), templates are transformed into working code samples with proper validation and testing.

### Supported Languages

- **C# (.NET 9.0)** - Full support with validation pipeline
- **Python** - Full support with validation pipeline  
- **Java** - Full support with validation pipeline
- **Go** - Full support with validation pipeline
- **JavaScript/Node.js** - Template support available

### Available Sample Categories

- **Audio Transcription** (sync/async)
- **Chat Completion** (basic, streaming, conversation, structured outputs)
- **Chat with Vision** (image input, reasoning)
- **Embeddings** (sync/async)
- **Image Generation** (sync/async)
- **Response Handling** (basic, streaming, file input, image input)

## 📁 Repository Structure

```
├── ci/                             # Azure DevOps pipeline configuration
├── samples/                         # Template source files
│   ├── input-data.yaml              # Configuration for generating samples
│   └── {sample-name}                # Individual sample templates
│       ├── csharp/                  # C# templates
│       ├── python/                  # Python templates
│       ├── {etc.}/                  # templates other supported languages
├── scripts/                         # Build and validation scripts
├── validation-config-defaults/      # Language-specific validation configs
├── generated-samples/               # Output folder when run generation sequence is run (locally or pipeline)
│   ├── csharp/                      # Generated C# samples
│   ├── python/                      # Generated Python samples
│   └── {etc.}/                      # Generated Java samples
```

## 🛠️ Getting Started

### Prerequisites

- **Dev Container**: This repository includes a complete dev container setup with all required tools
- **Manual Setup**: If not using dev containers, you'll need:
  - .NET SDK 9.x
  - Python 3.11+
  - Java 17+ (for Java samples)
  - Node.js 14+ (for tooling)
  - Azure CLI

### Quick Start

1. **Clone the repository**:
   ```bash
   git clone https://github.com/Azure-Samples/template-samples.git
   cd template-samples
   ```

2. **Open in dev container** (recommended):
   - Use VS Code with Remote-Containers extension
   - Open Command Palette → "Remote-Containers: Reopen in Container"

3. **Generate samples**:
   ```bash
   npm install -g @caleuche/cli
   che batch samples/input-data.yaml
   ```

4. **[COMING SOON] View samples in the web UI**:
   ```bash
   cd mockUI
   npm install
   npm start
   ```

## 🔧 Development Workflow

### Adding New Samples

1. **Create template directory**:
   ```bash
   mkdir -p samples/my-new-sample/{csharp,python,java,go}
   ```

2. **Create template files**:
   - Add `sample.{language}.template` files for each supported language
   - Add accompanying `sample.yaml` template input configuration to populate templated syntax with dynamic content, e.g. `<%= endpoint %>`

3. **Configure sample generation**:
   - Add entry to [`samples/input-data.yaml`](samples/input-data.yaml)
   - Define input parameters and output paths

4. **Optional: Add validation overrides**:
   - Create `.validation-config.json` in language directories
   - Override default build/validation steps if needed

### Template Syntax

Templates use EJS-style syntax with language-specific helpers:

```csharp
// C# template example
using Azure.AI.OpenAI;

public class Sample {
    public static async Task Main(string[] args) {
        var endpoint = "<%= endpoint %>";
        var deploymentName = "<%= deploymentName %>";
        // ... rest of implementation
    }
}
```
See more on the [Caleuche](https://github.com/brandor64/caleuche) repo or in the existing templates under [samples](samples/)

### Validation Configuration

Each language has default validation steps defined in [`validation-config-defaults/`](validation-config-defaults/):

```json
{
  "language": "csharp",
  "framework": "net9.0",
  "buildSteps": [
    "dotnet restore",
    "dotnet build"
  ],
  "validationLevel": "compile-only"
}
```

## 🔄 CI/CD Pipeline

The Azure DevOps pipeline automatically:

1. **Generates samples** from templates using Caleuche CLI
2. **Detects changes** to any modified samples
3. **Validates samples** for each language:
   - Compiles code to ensure syntax correctness
   - Runs static analysis and formatting checks
   - Validates proper SDK usage patterns
4. **Publishes artifacts** of all generated samples that pass validation

## [COMING SOON] 🌐 Web Interface

The [`mockUI/`](mockUI/) directory contains a clean web interface for viewing and testing generated samples:

- **Multi-language support** with syntax highlighting
- **API and capability selection** via dropdown
- **Real-time updates** when samples change
- **Copy-to-clipboard** functionality
