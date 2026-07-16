#!/usr/bin/env bash

# Shared helpers for hosted-agent session quota retries.

hosted_agent_is_session_quota_error() {
  [ "$#" -gt 0 ] || return 1
  grep -qihE \
    'SessionQuotaExceeded|RegionalSessionQuotaExceeded|session_quota_exceeded|regional_session_quota_exceeded' \
    "$@" 2>/dev/null
}

hosted_agent_quota_retry_delay() {
  if [ -n "${HOSTED_AGENT_QUOTA_RETRY_DELAY_SECONDS:-}" ]; then
    printf '%s\n' "$HOSTED_AGENT_QUOTA_RETRY_DELAY_SECONDS"
    return
  fi

  # Jitter around one minute so blocked cells do not retry simultaneously.
  printf '%s\n' "$((50 + RANDOM % 21))"
}
