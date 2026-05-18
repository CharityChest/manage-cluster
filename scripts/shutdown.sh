#!/usr/bin/env bash
#
# shutdown.sh — scale every Fargate service in an ECS cluster to 0 desired
# tasks and stop a Postgres RDS instance.
#
# RDS note: a stopped instance is auto-started by AWS after 7 days. Re-run
# this script (or schedule it) to keep it stopped longer.
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
#   ECS_CLUSTER      ECS cluster name
#   RDS_INSTANCE_ID  RDS DB instance identifier
# Optional:
#   ECS_SERVICES     space-separated list of service names; if unset, every
#                    service in the cluster is scaled to 0
#   AWS_PROFILE      passed through to the AWS CLI
#   ASSUME_YES=1     skip the confirmation prompt (useful for cron)

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
  read -r -p "Shut down ECS cluster '${ECS_CLUSTER}' and RDS '${RDS_INSTANCE_ID}' in ${AWS_REGION}? [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

list_services() {
  if [[ -n "${ECS_SERVICES:-}" ]]; then
    printf '%s\n' ${ECS_SERVICES}
    return
  fi
  # list-services paginates the service ARNs; the names are after the last "/"
  "${AWS[@]}" ecs list-services \
    --cluster "${ECS_CLUSTER}" \
    --output text \
    --query 'serviceArns[]' \
    | tr '\t' '\n' \
    | awk -F/ 'NF{print $NF}'
}

scale_services_to_zero() {
  local services=()
  mapfile -t services < <(list_services)

  if [[ ${#services[@]} -eq 0 ]]; then
    log "no services found in cluster '${ECS_CLUSTER}' — nothing to scale"
    return
  fi

  for svc in "${services[@]}"; do
    local current
    current="$("${AWS[@]}" ecs describe-services \
      --cluster "${ECS_CLUSTER}" \
      --services "${svc}" \
      --output text \
      --query 'services[0].desiredCount')"

    if [[ "${current}" == "0" ]]; then
      log "service ${svc}: desiredCount already 0 — skipping"
      continue
    fi

    log "service ${svc}: scaling ${current} -> 0"
    "${AWS[@]}" ecs update-service \
      --cluster "${ECS_CLUSTER}" \
      --service "${svc}" \
      --desired-count 0 \
      --no-cli-pager \
      >/dev/null
  done
}

stop_rds_instance() {
  local status
  status="$("${AWS[@]}" rds describe-db-instances \
    --db-instance-identifier "${RDS_INSTANCE_ID}" \
    --output text \
    --query 'DBInstances[0].DBInstanceStatus')"

  case "${status}" in
    available)
      log "rds ${RDS_INSTANCE_ID}: status=available — stopping"
      "${AWS[@]}" rds stop-db-instance \
        --db-instance-identifier "${RDS_INSTANCE_ID}" \
        --no-cli-pager \
        >/dev/null
      ;;
    stopped|stopping)
      log "rds ${RDS_INSTANCE_ID}: status=${status} — skipping"
      ;;
    *)
      log "rds ${RDS_INSTANCE_ID}: status=${status} — not stoppable, skipping"
      ;;
  esac
}

main() {
  if ! confirm; then
    echo "aborted." >&2
    exit 1
  fi
  scale_services_to_zero
  stop_rds_instance
  log "done."
}

main "$@"
