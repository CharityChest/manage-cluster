#!/usr/bin/env bash
#
# manage-vpce.sh — create or delete a set of VPC endpoints (Interface and/or
# Gateway), described in a plain-text config file.
#
# Why this exists: interface endpoints (PrivateLink) accrue ~$0.01/hour per
# endpoint **per AZ** even when idle, so deleting them during a planned pause
# can save real money. Gateway endpoints (S3, DynamoDB) are free; managing
# them here is for completeness and symmetric teardown/setup.
#
# Scope is deliberately narrow — same boundary as manage-albs.sh:
#   - this script manages the endpoint resource itself (type, service,
#     subnets/SGs/route-tables, policy document, tags);
#   - it does NOT manage the VPC, subnets, route tables, security groups, or
#     the private hosted zone records auto-published when
#     private_dns_enabled=true (those are AWS-managed).
#
# If your VPC endpoints are owned by Terraform in the sibling repo, deleting
# them here will cause drift on the next `terraform apply`. Confirm ownership
# before using this on shared infra.
#
# Idempotent:
#   - create: identity is `(vpc_id, service_name)` — the natural primary key
#     for a VPC endpoint, since AWS only allows one endpoint per service per
#     VPC. If an endpoint for the same service already exists in the
#     configured VPC, it is reused (no modify is attempted — see "Modify is
#     intentionally out of scope" below) regardless of how it was originally
#     created (this script, Console, Terraform, etc.). Its ID is logged so
#     re-runs after a partial failure complete the set.
#   - delete: missing endpoints (by service_name in the configured VPC) are
#     silently skipped. The section header is still applied as the Name tag
#     at create time for Console readability, but it is not load-bearing for
#     lookup.
#
# Modify is intentionally out of scope: changing service_name or vpc_id
# requires a recreate, and changing subnets/SGs/policy on an existing
# endpoint is rare for this cost-management use case. If you need to rotate
# a policy without recreating, do it manually with
# `aws ec2 modify-vpc-endpoint`.
#
# Usage:
#   ./manage-vpce.sh create <config-file>
#   ./manage-vpce.sh delete <config-file>
#
# Config file format (INI-style, one [name] section per endpoint):
#
#   # Interface endpoint with a per-endpoint policy.
#   [cc-ecr-api-dev]
#   type=Interface
#   service_name=com.amazonaws.eu-central-1.ecr.api
#   vpc_id=vpc-0123456789abcdef0
#   subnets=subnet-0346805ef41afa4f1,subnet-0834675ec2670bf5f
#   security_groups=sg-0e6894f14a502c771
#   private_dns_enabled=true
#   policy_file=policies/ecr-api.json
#   tags=Env=dev,App=charity-chest
#
#   # Gateway endpoint (S3) — needs route tables, no subnets/SGs/DNS.
#   [cc-s3-dev]
#   type=Gateway
#   service_name=com.amazonaws.eu-central-1.s3
#   vpc_id=vpc-0123456789abcdef0
#   route_table_ids=rtb-0aaa,rtb-0bbb
#   policy_file=policies/s3-readonly.json
#
# Per-section keys:
#   type                 Interface | Gateway                          (required)
#   service_name         e.g. com.amazonaws.<region>.ecr.api          (required)
#   vpc_id               vpc-...                                      (required)
#   subnets              comma-separated subnet IDs                   (Interface only, required)
#   security_groups      comma-separated SG IDs                       (Interface only, required)
#   private_dns_enabled  true | false (default: true)                 (Interface only)
#   route_table_ids      comma-separated route-table IDs              (Gateway only, required)
#   policy_file          path to a JSON policy doc; relative paths are
#                        resolved against the config file's directory. Omit
#                        to let AWS apply its default full-access policy.
#   tags                 comma-separated Key=Value (Name is set automatically
#                        from the section header and should not be repeated)
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-central-1
# Optional:
#   AWS_PROFILE      passed through to the AWS CLI
#   ASSUME_YES=1     skip the confirmation prompt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <create|delete> <config-file>" >&2
  exit 2
fi

ACTION="$1"
CONFIG_FILE="$2"

: "${AWS_REGION:?AWS_REGION is required}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found in PATH" >&2
  exit 127
fi

if [[ ! -r "${CONFIG_FILE}" ]]; then
  echo "error: config file not readable: ${CONFIG_FILE}" >&2
  exit 1
fi

CONFIG_DIR="$(cd "$(dirname "${CONFIG_FILE}")" && pwd)"

AWS=(aws --region "${AWS_REGION}")

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

declare -A CONFIG
ENDPOINTS_ORDERED=()

parse_config() {
  local line raw_line current="" key value line_no=0
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line_no=$(( line_no + 1 ))
    line="${raw_line%$'\r'}"

    if [[ "${line}" =~ ^[[:space:]]*$ ]]; then continue; fi
    if [[ "${line}" =~ ^[[:space:]]*# ]]; then continue; fi

    if [[ "${line}" =~ ^[[:space:]]*\[([^\]]+)\][[:space:]]*$ ]]; then
      current="$(trim "${BASH_REMATCH[1]}")"
      if [[ -z "${current}" ]]; then
        echo "error: ${CONFIG_FILE}:${line_no}: empty section header" >&2
        exit 1
      fi
      ENDPOINTS_ORDERED+=("${current}")
      continue
    fi

    if [[ -z "${current}" ]]; then
      echo "error: ${CONFIG_FILE}:${line_no}: key=value before any [section]" >&2
      exit 1
    fi

    if [[ "${line}" != *"="* ]]; then
      echo "error: ${CONFIG_FILE}:${line_no}: expected key=value (got '${line}')" >&2
      exit 1
    fi

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    CONFIG["${current}.${key}"]="${value}"
  done < "${CONFIG_FILE}"

  if [[ ${#ENDPOINTS_ORDERED[@]} -eq 0 ]]; then
    echo "error: ${CONFIG_FILE} declares no endpoints" >&2
    exit 1
  fi
}

require_key() {
  local name="$1" key="$2"
  if [[ -z "${CONFIG["${name}.${key}"]:-}" ]]; then
    echo "error: endpoint '${name}' is missing required key '${key}'" >&2
    exit 1
  fi
}

# Resolve a policy_file value to an absolute path (relative to CONFIG_DIR).
resolve_policy_path() {
  local p="$1"
  if [[ -z "${p}" ]]; then return; fi
  if [[ "${p}" = /* ]]; then
    printf '%s' "${p}"
  else
    printf '%s/%s' "${CONFIG_DIR}" "${p}"
  fi
}

validate_endpoint() {
  local name="$1"
  require_key "${name}" type
  require_key "${name}" service_name
  require_key "${name}" vpc_id

  local type="${CONFIG["${name}.type"]}"
  case "${type}" in
    Interface)
      require_key "${name}" subnets
      require_key "${name}" security_groups
      local pdns="${CONFIG["${name}.private_dns_enabled"]:-true}"
      case "${pdns}" in
        true|false) ;;
        *) echo "error: endpoint '${name}': private_dns_enabled must be 'true' or 'false' (got '${pdns}')" >&2; exit 1 ;;
      esac
      if [[ -n "${CONFIG["${name}.route_table_ids"]:-}" ]]; then
        echo "error: endpoint '${name}': route_table_ids is not valid for type=Interface" >&2
        exit 1
      fi
      ;;
    Gateway)
      require_key "${name}" route_table_ids
      for k in subnets security_groups private_dns_enabled; do
        if [[ -n "${CONFIG["${name}.${k}"]:-}" ]]; then
          echo "error: endpoint '${name}': ${k} is not valid for type=Gateway" >&2
          exit 1
        fi
      done
      ;;
    *)
      echo "error: endpoint '${name}': type must be 'Interface' or 'Gateway' (got '${type}')" >&2
      exit 1
      ;;
  esac

  local policy="${CONFIG["${name}.policy_file"]:-}"
  if [[ -n "${policy}" ]]; then
    local abs
    abs="$(resolve_policy_path "${policy}")"
    if [[ ! -r "${abs}" ]]; then
      echo "error: endpoint '${name}': policy_file not readable: ${abs}" >&2
      exit 1
    fi
  fi
}

# describe_vpce <service_name> <vpc_id> — prints VpcEndpointId, or returns 1
# if absent. Identity is (vpc_id, service_name): AWS allows only one endpoint
# per service per VPC, so this is the natural primary key. Looking up by
# service name rather than Name tag means we find endpoints regardless of
# how they were created (this script, Console, Terraform, etc.).
describe_vpce() {
  local service_name="$1" vpc_id="$2"
  local id
  id="$("${AWS[@]}" ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=service-name,Values=${service_name}" \
    --output text \
    --query 'VpcEndpoints[0].VpcEndpointId' 2>/dev/null)" || return 1
  if [[ -z "${id}" || "${id}" == "None" ]]; then
    return 1
  fi
  printf '%s' "${id}"
}

create_one() {
  local name="$1"
  local type="${CONFIG["${name}.type"]}"
  local service="${CONFIG["${name}.service_name"]}"
  local vpc_id="${CONFIG["${name}.vpc_id"]}"
  local tags_csv="${CONFIG["${name}.tags"]:-}"
  local policy="${CONFIG["${name}.policy_file"]:-}"

  local existing_id
  if existing_id="$(describe_vpce "${service}" "${vpc_id}")"; then
    log "vpce ${name}: already exists for ${service} (${existing_id}) — reusing"
    return
  fi

  # Build --tag-specifications as a single shorthand string. Name is always
  # set from the section header; the user-supplied tags are appended.
  local tag_pairs="{Key=Name,Value=${name}}"
  if [[ -n "${tags_csv}" ]]; then
    local kv k v
    local IFS=','
    for kv in ${tags_csv}; do
      k="${kv%%=*}"
      v="${kv##*=}"
      if [[ -z "${k}" || "${k}" == "${kv}" ]]; then
        echo "error: endpoint '${name}': malformed tag '${kv}' (expected Key=Value)" >&2
        exit 1
      fi
      if [[ "${k}" == "Name" ]]; then
        echo "error: endpoint '${name}': do not set a Name tag in 'tags' — the section header is used" >&2
        exit 1
      fi
      tag_pairs+=",{Key=${k},Value=${v}}"
    done
  fi
  local tag_spec="ResourceType=vpc-endpoint,Tags=[${tag_pairs}]"

  local args=(
    ec2 create-vpc-endpoint
    --vpc-endpoint-type "${type}"
    --service-name "${service}"
    --vpc-id "${vpc_id}"
    --tag-specifications "${tag_spec}"
  )

  case "${type}" in
    Interface)
      local subnets_csv="${CONFIG["${name}.subnets"]}"
      local sgs_csv="${CONFIG["${name}.security_groups"]}"
      local pdns="${CONFIG["${name}.private_dns_enabled"]:-true}"
      args+=(--subnet-ids ${subnets_csv//,/ })
      args+=(--security-group-ids ${sgs_csv//,/ })
      if [[ "${pdns}" == "true" ]]; then
        args+=(--private-dns-enabled)
      else
        args+=(--no-private-dns-enabled)
      fi
      ;;
    Gateway)
      local rts_csv="${CONFIG["${name}.route_table_ids"]}"
      args+=(--route-table-ids ${rts_csv//,/ })
      ;;
  esac

  if [[ -n "${policy}" ]]; then
    local policy_path
    policy_path="$(resolve_policy_path "${policy}")"
    args+=(--policy-document "file://${policy_path}")
    log "vpce ${name}: creating (${type}, ${service}) with policy ${policy}"
  else
    log "vpce ${name}: creating (${type}, ${service}) with AWS default policy"
  fi

  "${AWS[@]}" "${args[@]}" \
    --no-cli-pager \
    --output text \
    --query 'VpcEndpoint.VpcEndpointId'
}

delete_one() {
  local name="$1"
  local vpc_id="${CONFIG["${name}.vpc_id"]}"
  local service="${CONFIG["${name}.service_name"]}"
  local id
  if ! id="$(describe_vpce "${service}" "${vpc_id}")"; then
    log "vpce ${name}: not found in ${vpc_id} (service=${service}) — skipping"
    return
  fi
  log "vpce ${name}: deleting ${service} (${id})"
  # delete-vpc-endpoints is a batch API; capture Unsuccessful for visibility.
  "${AWS[@]}" ec2 delete-vpc-endpoints \
    --vpc-endpoint-ids "${id}" \
    --no-cli-pager \
    --output text \
    --query 'Unsuccessful[].[VpcEndpointId,Error.Code,Error.Message]'
}

do_create() {
  local name
  for name in "${ENDPOINTS_ORDERED[@]}"; do
    validate_endpoint "${name}"
  done

  log "config declares ${#ENDPOINTS_ORDERED[@]} endpoint(s): ${ENDPOINTS_ORDERED[*]}"
  if ! confirm "Create (or reuse) these VPC endpoints in ${AWS_REGION}?"; then
    echo "aborted." >&2
    exit 1
  fi

  for name in "${ENDPOINTS_ORDERED[@]}"; do
    create_one "${name}"
  done

  log "done."
}

validate_for_delete() {
  local name="$1"
  require_key "${name}" vpc_id
  require_key "${name}" service_name
}

do_delete() {
  local name
  for name in "${ENDPOINTS_ORDERED[@]}"; do
    validate_for_delete "${name}"
  done

  log "config declares ${#ENDPOINTS_ORDERED[@]} endpoint(s) to delete: ${ENDPOINTS_ORDERED[*]}"
  if ! confirm "DELETE these VPC endpoints in ${AWS_REGION}? (private DNS records auto-published by AWS are removed with them; route-table associations on Gateway endpoints are also removed)"; then
    echo "aborted." >&2
    exit 1
  fi

  for name in "${ENDPOINTS_ORDERED[@]}"; do
    delete_one "${name}"
  done

  log "done."
}

main() {
  parse_config

  case "${ACTION}" in
    create) do_create ;;
    delete) do_delete ;;
    *)
      echo "error: unknown action '${ACTION}' (expected create|delete)" >&2
      exit 2
      ;;
  esac
}

main "$@"
