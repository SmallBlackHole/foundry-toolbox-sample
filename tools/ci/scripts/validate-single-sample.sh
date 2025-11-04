#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../../.."

SAMPLE_DIR=$1
MAKE_SERVICE_CALLS=${2:-false}
LANGUAGE=$3

# Resolve configuration

CONFIG=$("$SCRIPT_DIR/resolve-sample-configs.sh" "$SAMPLE_DIR" "$LANGUAGE")
LANGUAGE=$(echo "$CONFIG" | jq -r '.language')

echo "Language: $LANGUAGE"

# Save current directory and change to sample directory
ORIGINAL_DIR=$(pwd)
cd "$SAMPLE_DIR"

# If the current directory has a `tags.yaml` file with the tag `bypassValidation`,
# then we skip validation even if requested.
if [ -f "tags.yaml" ]; then
    if grep -q "bypassValidation" tags.yaml; then
        echo "‼️ 'bypassValidation' tag found in tags.yaml. Skipping validation steps."
        # `exit 0` here is needed to have this entry included in the collection of samples we publish.
        exit 0
    fi
fi

IN_PIPELINE_TEST_DIR=false
TEST_DIR="test"

# For Java, always use test directory if it exists (to avoid duplicate class compilation issues)
# For other languages, only use test directory when service calls are requested
if [ "$LANGUAGE" = "java" ] && [ -d "$TEST_DIR" ]; then
    echo ""
    echo "Java sample detected with '$TEST_DIR' directory. Moving to test subdirectory to avoid compilation conflicts."
    echo ""
    cd "$TEST_DIR"
    IN_PIPELINE_TEST_DIR=true
elif [ "$MAKE_SERVICE_CALLS" = true ] && [ -d "$TEST_DIR" ]; then
    echo ""
    echo "Service validation requested and detected a '$TEST_DIR' directory. Proceeding to run tests from subdirectory."
    echo ""
    cd "$TEST_DIR"
    IN_PIPELINE_TEST_DIR=true
fi

# Execute preBuild steps
echo ""
echo "--- PreBuild Steps ---"
echo "$CONFIG" | jq -r '.preBuildSteps[]?' | while IFS= read -r step; do
    if [ -n "$step" ] && [ "$step" != "null" ]; then
        echo "Executing: $step"
        eval "$step"
    fi
done

# Execute build steps
echo ""
echo "--- Build Steps ---"
echo "$CONFIG" | jq -r '.buildSteps[]?' | while IFS= read -r step; do
    if [ -n "$step" ] && [ "$step" != "null" ]; then
        echo "Executing: $step"
        eval "$step"
    fi
done

if [ "$MAKE_SERVICE_CALLS" = true ]; then
    if [ ! "$IN_PIPELINE_TEST_DIR" = true ]; then
        echo "⚠️ Service validation is requested but no '$TEST_DIR' directory was found. Skipping validation."
        exit 1
    else
        echo "--- Execution Steps ---"
        echo "$CONFIG" | jq -r '.executeSteps[]?' | while IFS= read -r step; do
            if [ -n "$step" ] && [ "$step" != "null" ]; then
                echo "Executing: $step"
                eval "$step"
            fi
        done
    fi
fi

# Execute validation steps
# echo ""
# echo "--- Validation Steps ---"
# echo "$CONFIG" | jq -r '.validateSteps[]?' | while IFS= read -r step; do
#     if [ -n "$step" ] && [ "$step" != "null" ]; then
#         echo "Executing: $step"
#         eval "$step"
#     fi
# done

# Return to original directory
cd "$ORIGINAL_DIR"

echo "✅ Validation completed"