#!/bin/bash
source logger.sh
source graceful-stop.sh
trap graceful_stop_term TERM

dumb-init bash <<'SCRIPT' &
source logger.sh
source wait.sh

DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"

if [ -e "${DOCKER_DAEMON_CONFIG}" ]; then
  printf -- '---\n' 1>&2
  cat ${DOCKER_DAEMON_CONFIG} | jq . 1>&2
  printf -- '---\n' 1>&2
else
  log.debug 'Docker daemon config file not supplied'
fi

log.debug 'Starting Docker daemon'
sudo service docker start &

log.debug 'Waiting for processes to be running...'
processes=(dockerd)

for process in "${processes[@]}"; do
    if ! wait_for_process "$process"; then
        log.error "$process is not running after max time"
        exit 1
    else
        log.debug "$process is running"
    fi
done

startup.sh

SCRIPT

RUNNER_INIT_PID=$!
log.notice "Runner init started with pid $RUNNER_INIT_PID"
wait $RUNNER_INIT_PID
log.notice "Runner init exited. Exiting this process with code 0."

trap - TERM
