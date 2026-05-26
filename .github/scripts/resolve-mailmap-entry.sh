#!/usr/bin/env bash
# resolve-mailmap-entry.sh — Resolve a Microsoft alias to a GitHub noreply email.
#
# Attempts to find the GitHub account for a Microsoft alias and returns a
# proposed sync-mailmap entry.
#
# Usage:
#   resolve-mailmap-entry.sh <alias> [<display-name>]
#
# Arguments:
#   alias         Microsoft alias (e.g., "jsmith" from jsmith@microsoft.com)
#   display-name  Optional: git commit author name for the entry
#
# Output (stdout):
#   On high confidence: a mailmap-format line, e.g.:
#     John Smith <12345+jsmith@users.noreply.github.com> <jsmith@microsoft.com>
#   On medium/low confidence: a "# VERIFY (confidence: ...)" comment line
#   followed by a valid mailmap-format line on the next line. The entry is
#   still a real mapping (git mailmap ignores the comment but applies the
#   mapping); the comment flags it for human review.
#
# Exit codes:
#   0  Resolution found (high or low confidence)
#   1  No resolution found — human lookup needed
#
# Environment:
#   GH_TOKEN  Optional: GitHub token for API calls (increases rate limit)

set -euo pipefail

ALIAS="${1:-}"
DISPLAY_NAME="${2:-}"

if [[ -z "$ALIAS" ]]; then
    echo "Usage: resolve-mailmap-entry.sh <alias> [<display-name>]" >&2
    exit 1
fi

INTERNAL_EMAIL="${ALIAS}@microsoft.com"
CONFIDENCE="none"
GH_LOGIN=""
GH_ID=""
GH_NAME=""

# ─── Strategy 1: Direct username lookup ───────────────────────────────────────
# Try the alias directly as a GitHub username

try_gh_user() {
    local login="$1"
    local id name

    if ! id=$(gh api "/users/$login" --jq '.id' 2>/dev/null); then
        return 1
    fi
    name=$(gh api "/users/$login" --jq '.name // empty' 2>/dev/null) || true

    if [[ -n "$id" ]]; then
        GH_LOGIN="$login"
        GH_ID="$id"
        GH_NAME="${name:-}"
        return 0
    fi
    return 1
}

# ─── Strategy 2: Search API ──────────────────────────────────────────────────

try_gh_search() {
    local query="$1"
    local count login id

    count=$(gh api "/search/users?q=${query}+in:login&per_page=1" --jq '.total_count' 2>/dev/null) || return 1

    if [[ "${count:-0}" -gt 0 ]]; then
        login=$(gh api "/search/users?q=${query}+in:login&per_page=1" --jq '.items[0].login' 2>/dev/null) || return 1
        id=$(gh api "/search/users?q=${query}+in:login&per_page=1" --jq '.items[0].id' 2>/dev/null) || return 1

        if [[ -n "$login" && -n "$id" ]]; then
            GH_LOGIN="$login"
            GH_ID="$id"
            return 0
        fi
    fi
    return 1
}

# ─── Resolution attempts ─────────────────────────────────────────────────────

if command -v gh &>/dev/null; then
    # Try direct alias lookup
    if try_gh_user "$ALIAS"; then
        # Validate: does the name or company suggest this is the right person?
        if [[ -n "$GH_NAME" && -n "$DISPLAY_NAME" ]]; then
            # Simple check: first or last name overlap
            display_lower="${DISPLAY_NAME,,}"
            gh_lower="${GH_NAME,,}"
            if [[ "$display_lower" == *"${gh_lower%% *}"* ]] || \
               [[ "$gh_lower" == *"${display_lower%% *}"* ]]; then
                CONFIDENCE="high"
            else
                CONFIDENCE="low"
            fi
        elif [[ -z "$GH_NAME" ]]; then
            # No GH display name to cross-check
            CONFIDENCE="low"
        else
            CONFIDENCE="medium"
        fi
    fi
    
    # If direct lookup failed, try common Microsoft patterns
    if [[ "$CONFIDENCE" == "none" ]]; then
        for suffix in "msft" "microsoft" "-msft"; do
            if try_gh_user "${ALIAS}${suffix}"; then
                CONFIDENCE="medium"
                break
            fi
        done
    fi

    # If suffix patterns failed, fall back to search API
    if [[ "$CONFIDENCE" == "none" ]]; then
        if try_gh_search "$ALIAS"; then
            CONFIDENCE="low"
        fi
    fi
fi

# ─── Build output ────────────────────────────────────────────────────────────

if [[ "$CONFIDENCE" == "none" ]]; then
    # No resolution — output guidance for human
    echo "# UNRESOLVED: ${DISPLAY_NAME:-$ALIAS} <???> <${INTERNAL_EMAIL}>" 
    echo "# Lookup: https://repos.opensource.microsoft.com/people?q=${ALIAS}" >&2
    exit 1
fi

# Build the noreply email
NOREPLY="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
ENTRY_NAME="${DISPLAY_NAME:-${GH_NAME:-$GH_LOGIN}}"

if [[ "$CONFIDENCE" == "high" ]]; then
    echo "${ENTRY_NAME} <${NOREPLY}> <${INTERNAL_EMAIL}>"
elif [[ "$CONFIDENCE" == "medium" || "$CONFIDENCE" == "low" ]]; then
    # Emit a VERIFY annotation followed by the real mailmap entry. The comment
    # line is ignored by git mailmap, so the entry below it still maps the
    # email — humans just know to double-check before merging.
    echo "# VERIFY (confidence: ${CONFIDENCE}): auto-resolved ${ALIAS} → ${GH_LOGIN}"
    echo "${ENTRY_NAME} <${NOREPLY}> <${INTERNAL_EMAIL}>"
fi

exit 0
