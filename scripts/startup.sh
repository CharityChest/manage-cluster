#!/usr/bin/env bash
#
# startup.sh — inverse of shutdown.sh: start a stopped Postgres RDS instance
# and scale Fargate services back up to a desired count.
#
# Order of operations:
#   1. Start the RDS instance (asynchronous; RDS takes several minutes).
#   2. Optionally wait for status=available (WAIT_FOR_RDS=1).
#   3. Scale each ECS service to its target desired count.
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
#   ECS_CLUSTER      ECS cluster name
#   RDS_INSTANCE_ID  RDS DB instance identifier
# Optional:
#   ECS_SERVICES         space-separated list of service names; if unset,
#                        every service in the cluster is scaled up
#   ECS_DESIRED_COUNTS   space-separated "name=count" overrides, e.g.
#                        "charity-chest-server=2 charity-chest-webapp=1"
#   DESIRED_COUNT        fallback target for services without an override
#                        (default: 1)
#   WAIT_FOR_RDS         set to 1 to block until RDS reports "available"
#                        before scaling services (default: 0)
#   AWS_PROFILE          passed through to the AWS CLI
#   ASSUME_YES=1         skip the confirmation prompt (useful for cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECS_CLUSTER:?ECS_CLUSTER is required}"
: "${RDS_INSTANCE_ID:?RDS_INSTANCE_ID is required}"

DESIRED_COUNT="${DESIRED_COUNT:-1}"
WAIT_FOR_RDS="${WAIT_FOR_RDS:-0}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found in PATH" >&2
  exit 127
fi

AWS=(aws --region "${AWS_REGION}")

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "Start RDS '${RDS_INSTANCE_ID}' and scale ECS cluster '${ECS_CLUSTER}' up in ${AWS_REGION}? [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

list_services() {
  if [[ -n "${ECS_SERVICES:-}" ]]; then
    printf '%s\n' ${ECS_SERVICES}
    return
  fi
  "${AWS[@]}" ecs list-services \
    --cluster "${ECS_CLUSTER}" \
    --output text \
    --query 'serviceArns[]' \
    | tr '\t' '\n' \
    | awk -F/ 'NF{print $NF}'
}

# desired_count_for <service> -> echoes the target desired count
desired_count_for() {
  local svc="$1"
  if [[ -n "${ECS_DESIRED_COUNTS:-}" ]]; then
    for entry in ${ECS_DESIRED_COUNTS}; do
      local name="${entry%%=*}"
      local count="${entry##*=}"
      if [[ "${name}" == "${svc}" ]]; then
        printf '%s\n' "${count}"
        return
      fi
    done
  fi
  printf '%s\n' "${DESIRED_COUNT}"
}

start_rds_instance() {
  local status
  status="$("${AWS[@]}" rds describe-db-instances \
    --db-instance-identifier "${RDS_INSTANCE_ID}" \
    --output text \
    --query 'DBInstances[0].DBInstanceStatus')"

  case "${status}" in
    stopped)
      log "rds ${RDS_INSTANCE_ID}: status=stopped — starting"
      "${AWS[@]}" rds start-db-instance \
        --db-instance-identifier "${RDS_INSTANCE_ID}" \
        --no-cli-pager \
        >/dev/null
      ;;
    available|starting)
      log "rds ${RDS_INSTANCE_ID}: status=${status} — skipping start"
      ;;
    *)
      log "rds ${RDS_INSTANCE_ID}: status=${status} — not startable from this state, continuing"
      ;;
  esac
}

wait_for_rds_available() {
  if [[ "${WAIT_FOR_RDS}" != "1" ]]; then
    return
  fi
  log "rds ${RDS_INSTANCE_ID}: waiting for status=available (this can take several minutes)"
  "${AWS[@]}" rds wait db-instance-available \
    --db-instance-identifier "${RDS_INSTANCE_ID}"
  log "rds ${RDS_INSTANCE_ID}: available"
}

scale_services_up() {
  local services=()
  mapfile -t services < <(list_services)

  if [[ ${#services[@]} -eq 0 ]]; then
    log "no services found in cluster '${ECS_CLUSTER}' — nothing to scale"
    return
  fi

  for svc in "${services[@]}"; do
    local target
    target="$(desired_count_for "${svc}")"

    local current
    current="$("${AWS[@]}" ecs describe-services \
      --cluster "${ECS_CLUSTER}" \
      --services "${svc}" \
      --output text \
      --query 'services[0].desiredCount')"

    if [[ "${current}" == "${target}" ]]; then
      log "service ${svc}: desiredCount already ${target} — skipping"
      continue
    fi

    log "service ${svc}: scaling ${current} -> ${target}"
    "${AWS[@]}" ecs update-service \
      --cluster "${ECS_CLUSTER}" \
      --service "${svc}" \
      --desired-count "${target}" \
      --no-cli-pager \
      >/dev/null
  done
}

main() {
  if ! confirm; then
    echo "aborted." >&2
    exit 1
  fi
  start_rds_instance
  wait_for_rds_available
  scale_services_up
  log "done."
}

main "$@"
