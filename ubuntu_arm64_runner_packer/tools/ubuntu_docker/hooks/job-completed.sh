#!/usr/bin/env bash
set -Eeuo pipefail

source logger.sh

log.debug "Running actions runner Job Completed Hooks"

for hook in /etc/actions-runner/hooks/job-completed.d/*; do
  log.debug "Running hook: $hook"
  "$hook" "$@"
done
