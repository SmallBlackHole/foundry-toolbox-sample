import { DefaultAzureCredential } from "@azure/identity";
import { AIProjectClient } from "@azure/ai-projects";
import "dotenv/config";

const projectEndpoint = process.env["PROJECT_ENDPOINT"] || "<project endpoint>";
const deploymentName = process.env["MODEL_DEPLOYMENT_NAME"] || "<model deployment name>";

async function main(): Promise<void> {
    const project = new AIProjectClient(projectEndpoint, new DefaultAzureCredential());
    const openAIClient = await project.getOpenAIClient();
    const response = await openAIClient.responses.create({
        model: deploymentName,
        input: "What is the size of France in square miles?",
    });
    const response2 = await openAIClient.responses.create({
        model: deploymentName,
        input: "And what is the capital city?",
        previous_response_id: response.id,
    });
    console.log(`Response output: ${response2.output_text}`);
};

main().catch(console.error);