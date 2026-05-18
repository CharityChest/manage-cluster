#!/usr/bin/env bash
#
# status.sh — read-only diagnostic. Prints desired/running/pending task
# counts for every Fargate service in the cluster plus the current RDS
# instance status. Performs no mutations.
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
#   ECS_CLUSTER      ECS cluster name
#   RDS_INSTANCE_ID  RDS DB instance identifier
# Optional:
#   ECS_SERVICES     space-separated list of service names; if unset, every
#                    service in the cluster is shown
#   AWS_PROFILE      passed through to the AWS CLI

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

print_ecs_status() {
  echo "ECS cluster: ${ECS_CLUSTER}  (region: ${AWS_REGION})"

  local services=()
  mapfile -t services < <(list_services)

  if [[ ${#services[@]} -eq 0 ]]; then
    echo "  (no services)"
    return
  fi

  # describe-services accepts up to 10 names per call; chunk to be safe
  local rows=""
  local i=0
  while (( i < ${#services[@]} )); do
    local chunk=("${services[@]:i:10}")
    rows+="$("${AWS[@]}" ecs describe-services \
      --cluster "${ECS_CLUSTER}" \
      --services "${chunk[@]}" \
      --output text \
      --query 'services[].[serviceName,desiredCount,runningCount,pendingCount,status]')"$'\n'
    i=$(( i + 10 ))
  done

  printf '  %-40s %8s %8s %8s %10s\n' SERVICE DESIRED RUNNING PENDING STATUS
  printf '%s' "${rows}" | awk '
    NF { printf "  %-40s %8s %8s %8s %10s\n", $1, $2, $3, $4, $5 }
  '
}

print_rds_status() {
  echo
  echo "RDS instance: ${RDS_INSTANCE_ID}"
  "${AWS[@]}" rds describe-db-instances \
    --db-instance-identifier "${RDS_INSTANCE_ID}" \
    --output text \
    --query 'DBInstances[0].[DBInstanceStatus,Engine,EngineVersion,Endpoint.Address,Endpoint.Port]' \
    | awk '
      {
        printf "  status:   %s\n", $1
        printf "  engine:   %s %s\n", $2, $3
        if ($4 != "None" && $4 != "") {
          printf "  endpoint: %s:%s\n", $4, $5
        }
      }
    '
}

main() {
  print_ecs_status
  print_rds_status
}

main "$@"
