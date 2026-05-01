#!/usr/bin/env bash
# Mint a short-lived GitHub App installation token for posting validation statuses.
#
# Required env:
#   GH_APP_ID               GitHub App ID
#   GH_APP_INSTALLATION_ID  GitHub App installation ID for microsoft-foundry/foundry-samples-pr
#   GH_APP_PRIVATE_KEY      PEM private key (multiline or with literal \n escapes)
#
# Output:
#   Prints the installation token to stdout. Azure Pipelines callers should capture
#   stdout and store it in a secret pipeline variable for later status-posting steps.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: mint-installation-token.sh [--print-jwt]

Prints a GitHub App installation token to stdout. --print-jwt is intended for
local smoke tests and prints only the signed JWT before the API exchange.
USAGE
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Required environment variable is not set: $name" >&2
        exit 2
    fi
}

base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

normalized_private_key() {
    # ADO secret variables often preserve PEMs as literal \n sequences.
    printf '%s' "$GH_APP_PRIVATE_KEY" | sed 's/\\n/\n/g' | tr -d '\r'
}

json_header() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc '{alg:"RS256",typ:"JWT"}'
    elif command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import json
print(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")))
PY
    else
        echo "Neither jq nor python3 is available to build JSON" >&2
        return 127
    fi
}

json_payload() {
    local iss="$1"
    local iat="$2"
    local exp="$3"
    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg iss "$iss" \
            --argjson iat "$iat" \
            --argjson exp "$exp" \
            '{iss:$iss,iat:$iat,exp:$exp}'
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$iss" "$iat" "$exp" <<'PY'
import json
import sys
print(json.dumps({"iss": sys.argv[1], "iat": int(sys.argv[2]), "exp": int(sys.argv[3])}, separators=(",", ":")))
PY
    else
        echo "Neither jq nor python3 is available to build JSON" >&2
        return 127
    fi
}

generate_jwt() {
    require_env GH_APP_ID
    require_env GH_APP_PRIVATE_KEY

    local now iat exp header payload unsigned signature
    now="$(date +%s)"
    iat=$((now - 60))
    exp=$((now + 600))

    header="$(json_header)"
    payload="$(json_payload "$GH_APP_ID" "$iat" "$exp")"

    unsigned="$(printf '%s' "$header" | base64url).$(printf '%s' "$payload" | base64url)"
    signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign <(normalized_private_key) -binary | base64url)"

    printf '%s.%s\n' "$unsigned" "$signature"
}

mint_installation_token() {
    require_env GH_APP_INSTALLATION_ID

    local jwt response token
    jwt="$(generate_jwt)"
    response="$(curl --fail-with-body -sS \
        -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens")"

    if command -v jq >/dev/null 2>&1; then
        token="$(printf '%s' "$response" | jq -r '.token // empty')"
    else
        token="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')"
    fi
    if [[ -z "$token" ]]; then
        echo "GitHub App token response did not include .token" >&2
        exit 1
    fi

    printf '%s\n' "$token"
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    if [[ "${1:-}" == "--print-jwt" ]]; then
        generate_jwt
        exit 0
    fi

    if [[ $# -gt 0 ]]; then
        usage
        exit 2
    fi

    mint_installation_token
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
