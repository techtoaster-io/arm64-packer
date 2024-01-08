#!/bin/bash
source logger.sh

RUNNER_ASSETS_DIR=${RUNNER_ASSETS_DIR:-/runnertmp}
RUNNER_HOME=${RUNNER_HOME:-/runner}
RUNNER_CONFIG_ARGS=${RUNNER_CONFIG_ARGS}
RUNNER_LABELS=${RUNNER_LABELS}
REPOSITORY=${REPOSITORY}
ENTERPRISE=${ENTERPRISE}
ORGANIZATION=${ORGANIZATION}
RUNNER_CONFIG_RETRIES=${RUNNER_CONFIG_RETRIES:-10}
RUNNER_CONFIG_RETRY_INTERVAL_SECONDS=${RUNNER_CONFIG_RETRY_INTERVAL_SECONDS:-10}
RUNNER_ADMIN_TOKEN=${RUNNER_ADMIN_TOKEN}
DOCKER_ENABLED=${DOCKER_ENABLED:-"true"}
DISABLE_WAIT_FOR_DOCKER=${DISABLE_WAIT_FOR_DOCKER:-"false"}

# The scripts are automatically executed when the runner has the following
# environment variables containing an absolute path to the script:
#    ACTIONS_RUNNER_HOOK_JOB_STARTED:   The script defined in this environment variable
#                                       is triggered when a job has been assigned to a runner,
#                                       but before the job starts running.
#    ACTIONS_RUNNER_HOOK_JOB_COMPLETED: The script defined in this environment variable is triggered at the end of the job,
#                                       after all the steps defined in the workflow have run.
export ACTIONS_RUNNER_HOOK_JOB_STARTED=/etc/actions-runner/hooks/job-started.sh
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/etc/actions-runner/hooks/job-completed.sh

if [ -n "${STARTUP_DELAY_IN_SECONDS}" ]; then
  log.notice "Delaying startup by ${STARTUP_DELAY_IN_SECONDS} seconds"
  sleep "${STARTUP_DELAY_IN_SECONDS}"
fi

github_api_pfx="https://api.github.com"
github_tgt_pfx="https://github.com"

if [[ "${REPOSITORY:-}" != '' ]]; then
  rest_api_ep="${github_api_pfx}/repos/${ORGANIZATION}/${REPOSITORY}"
  registration_url="${github_tgt_pfx}/${ORGANIZATION}/${REPOSITORY}"
fi

if [[ "${ORGANIZATION:-}" != '' ]]; then
  rest_api_ep="${github_api_pfx}/orgs/${ORGANIZATION}"
  registration_url="${github_tgt_pfx}/${ORGANIZATION}"
fi

if [[ "${ENTERPRISE:-}" != '' ]]; then
  rest_api_ep="https://api.github.com/enterprises/${ENTERPRISE}"
  registration_url="${github_tgt_pfx}/${ENTERPRISE}"
fi

rest_api_ep_runners_pfx=$(echo ${rest_api_ep}/actions/runners)
rest_api_ep_add_token=$(echo ${rest_api_ep_runners_pfx}/registration-token)
rest_api_ep_remove_token=$(echo ${rest_api_ep_runners_pfx}/remove-token)

if [ ! -d "${RUNNER_HOME}" ]; then
  log.notice "Runner home dir ${RUNNER_HOME} is missing, creating it..."
  sudo mkdir -p "${RUNNER_HOME}"
  sudo chown -R ${RUNNER_USER}:docker "$RUNNER_HOME"
  shopt -s dotglob
  cp -r "$RUNNER_ASSETS_DIR"/* "$RUNNER_HOME"/
  shopt -u dotglob

else
  log.error "$RUNNER_HOME should be an emptyDir mount"
  exit 1
fi

if ! cd "${RUNNER_HOME}"; then
  log.error "Failed to cd into ${RUNNER_HOME}"
  exit 1
fi

update-status "Registering"

retries_left=${RUNNER_CONFIG_RETRIES}

while [[ ${retries_left} -gt 0 ]]; do
  log.debug 'Configuring the runner.'
  runner_reg_token=$(echo $(curl -L -X POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${RUNNER_ADMIN_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" ${rest_api_ep_add_token} | jq .token --raw-output))
  runner_remove_token=$(echo $(curl -L -X POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${RUNNER_ADMIN_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" ${rest_api_ep_remove_token} | jq .token --raw-output))
  
  log.debug "labels assigned : ${RUNNER_LABELS}"

  if [[ "${RUNNER_CONFIG_ARGS:-}" != '' ]]; then
    if [[ "${RUNNER_LABELS:-}" != '' ]]; then
      ${RUNNER_HOME}/config.sh --url ${registration_url} --token ${runner_reg_token} ${RUNNER_CONFIG_ARGS} --labels "${RUNNER_LABELS}"
    else
      ${RUNNER_HOME}/config.sh --url ${registration_url} --token ${runner_reg_token} ${RUNNER_CONFIG_ARGS}
    fi
  else
    ${RUNNER_HOME}/config.sh --url ${registration_url} --token ${runner_reg_token}
  fi

  if [ -f ${RUNNER_HOME}/.runner ]; then
    log.debug 'Runner successfully configured.'
    break
  fi

  log.debug 'Configuration failed. Retrying'
  retries_left=$((${RUNNER_CONFIG_RETRIES} - 1))

  log.debug "Number of retries left before giving up -> ${retries_left} "
  sleep ${RUNNER_CONFIG_RETRY_INTERVAL_SECONDS}
done

if [ ! -f ${RUNNER_HOME}/.runner ]; then
  # couldn't configure and register the runner
  log.error 'Configuration failed!'
  exit 2
fi

cat ${RUNNER_HOME}/.runner
# Note: the `.runner` file's content should be something like the below:
# ----------------------------------------------------------------------
# $ cat ${RUNNER_HOME}/.runner
# {
#  "agentId": 426,
#  "agentName": "somerunner",
#  "poolId": 1,
#  "poolName": "some-runnergroup-name",
#  "disableUpdate": true,
#  "serverUrl": "https://pipelinesghubeus13.actions.githubusercontent.com/rZU6ldCEexQKjJTKI0qZFIEgV6GOKzbnLqm0X8GE7HIsQYIzpI/",
#  "gitHubUrl": "https://github.com/some-organization",
#  "workFolder": "_work"
# }

runner_id=$(cat ${RUNNER_HOME}/.runner | jq -r .agentId)
runner_name=$(cat ${RUNNER_HOME}/.runner | jq -r .agentName)
runner_group_id=$(cat ${RUNNER_HOME}/.runner | jq -r .poolId)
runner_group_name=$(cat ${RUNNER_HOME}/.runner | jq -r .agentName)
runner_work_folder=$(cat ${RUNNER_HOME}/.runner | jq -r .workFolder)

log.debug 'Waiting for processes to be running...'

WAIT_FOR_DOCKER_SECONDS=${WAIT_FOR_DOCKER_SECONDS:-120}
if [[ "${DISABLE_WAIT_FOR_DOCKER}" != "true" ]] && [[ "${DOCKER_ENABLED}" == "true" ]]; then
  log.debug 'Docker enabled runner detected and Docker daemon wait is enabled'
  log.debug "Waiting until Docker is available or the timeout of ${WAIT_FOR_DOCKER_SECONDS} seconds is reached"
  if ! timeout "${WAIT_FOR_DOCKER_SECONDS}s" bash -c 'until docker ps ;do sleep 1; done'; then
    log.notice "Docker has not become available within ${WAIT_FOR_DOCKER_SECONDS} seconds. Exiting with status 1."
    exit 1
  fi
else
  log.notice 'Docker wait check skipped. Either Docker is disabled or the wait is disabled, continuing with entrypoint'
fi

# Unset entrypoint environment variables so they don't leak into the runner environment
unset RUNNER_CONFIG_ARGS REPOSITORY RUNNER_ADMIN_TOKEN ORGANIZATION ENTERPRISE STARTUP_DELAY_IN_SECONDS DISABLE_WAIT_FOR_DOCKER runner_reg_token runner_remove_token

update-status "Idle"
exec env -- "${env[@]}" ./run.sh
