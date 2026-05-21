#!/usr/bin/env bash
#
# manage-albs.sh — create or delete a set of Application Load Balancers,
# described in a plain-text config file.
#
# On `create`, also emits up to two templates derived from the config:
#
#   - A DNS records template in the format expected by
#     scripts/apply-dns-records.sh, with one `alias` line per declared DNS
#     name pre-filled with the new ALB's DNSName and CanonicalHostedZoneId.
#   - A service-LB template in the format expected by
#     scripts/update-service-alb.sh, with one [service] section per declared
#     `ecs_service.*` block.
#
# Together with apply-dns-records.sh and update-service-alb.sh this gives a
# three-step pipeline (provision ALBs -> wire DNS -> wire ECS services).
#
# Listeners, target groups, and listener rules are intentionally **out of
# scope** — this script only manages the ALB shell. Target group ARNs in the
# config must already exist (created by Terraform or the deploy workflow).
#
# Idempotent:
#   - create: skips ALBs that already exist by name; their current DNS info
#     is still included in the records output so re-running produces a
#     complete records file.
#   - delete: skips ALBs that aren't present in the account.
#
# Usage:
#   ./manage-albs.sh create <config-file> [<dns-records-out>] [<service-lb-out>]
#   ./manage-albs.sh delete <config-file>
#
# Config file format (INI-style, one [name] section per ALB):
#
#   # Lines starting with '#' and blank lines are ignored.
#   [charity-chest-prod-alb]
#   scheme=internet-facing
#   ip_address_type=dualstack
#   subnets=subnet-aaa,subnet-bbb
#   security_groups=sg-xxx
#   dns_names=api.charitychest.com.,www.charitychest.com.
#   tags=Env=prod,App=charity-chest
#
#   # Optional: declare ECS services to associate with this ALB. Each
#   # service uses a triplet of dotted keys under `ecs_service.<svc>.*`.
#   # The generated service-LB template will contain one [<svc>] section
#   # per service, ready to feed to update-service-alb.sh.
#   ecs_service.charity-chest-server.cluster=charity-chest-prod
#   ecs_service.charity-chest-server.container_name=server
#   ecs_service.charity-chest-server.container_port=8080
#   ecs_service.charity-chest-server.target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/server-tg/abc
#
#   [charity-chest-stg-alb]
#   scheme=internet-facing
#   ip_address_type=ipv4
#   subnets=subnet-ccc,subnet-ddd
#   security_groups=sg-yyy
#   dns_names=api-stg.charitychest.com.
#
# - scheme:           internet-facing | internal
# - ip_address_type:  ipv4 | dualstack
# - subnets:          comma-separated subnet IDs (>=2 in distinct AZs)
# - security_groups:  comma-separated SG IDs
# - dns_names:        comma-separated FQDNs (trailing dot) used only to
#                     populate the records template emitted on create. Omit
#                     to skip records output for this ALB.
# - tags:             comma-separated Key=Value pairs (optional)
# - ecs_service.<name>.{cluster,container_name,container_port,target_group_arn}:
#                     optional ECS service associations used only to
#                     populate the service-LB template. target_group_arn
#                     must reference an existing target group.
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
# Optional:
#   AWS_PROFILE      passed through to the AWS CLI
#   ASSUME_YES=1     skip the confirmation prompt
#   WAIT_FOR_ACTIVE  set to 1 to block until each new ALB reaches state
#                    'active' (typically 2-5 minutes per ALB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <create|delete> <config-file> [<dns-records-out>] [<service-lb-out>]" >&2
  exit 2
fi

ACTION="$1"
CONFIG_FILE="$2"
OUTPUT_RECORDS_FILE="${3:-}"
OUTPUT_SERVICE_LB_FILE="${4:-}"

: "${AWS_REGION:?AWS_REGION is required}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found in PATH" >&2
  exit 127
fi

if [[ ! -r "${CONFIG_FILE}" ]]; then
  echo "error: config file not readable: ${CONFIG_FILE}" >&2
  exit 1
fi

AWS=(aws --region "${AWS_REGION}")

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# trim leading/trailing whitespace
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

declare -A CONFIG
declare -A ALB_ECS_SERVICES   # alb -> space-separated service names, in declaration order
ALBS_ORDERED=()

parse_config() {
  local line raw_line current_alb="" key value line_no=0
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line_no=$(( line_no + 1 ))
    line="${raw_line%$'\r'}"

    if [[ "${line}" =~ ^[[:space:]]*$ ]]; then continue; fi
    if [[ "${line}" =~ ^[[:space:]]*# ]]; then continue; fi

    if [[ "${line}" =~ ^[[:space:]]*\[([^\]]+)\][[:space:]]*$ ]]; then
      current_alb="$(trim "${BASH_REMATCH[1]}")"
      if [[ -z "${current_alb}" ]]; then
        echo "error: ${CONFIG_FILE}:${line_no}: empty section header" >&2
        exit 1
      fi
      ALBS_ORDERED+=("${current_alb}")
      continue
    fi

    if [[ -z "${current_alb}" ]]; then
      echo "error: ${CONFIG_FILE}:${line_no}: key=value before any [section]" >&2
      exit 1
    fi

    if [[ "${line}" != *"="* ]]; then
      echo "error: ${CONFIG_FILE}:${line_no}: expected key=value (got '${line}')" >&2
      exit 1
    fi

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    CONFIG["${current_alb}.${key}"]="${value}"

    if [[ "${key}" == ecs_service.* ]]; then
      local rest="${key#ecs_service.}"
      local svc_name="${rest%%.*}"
      if [[ -z "${svc_name}" || "${svc_name}" == "${rest}" ]]; then
        echo "error: ${CONFIG_FILE}:${line_no}: malformed ecs_service key '${key}' (expected ecs_service.<name>.<field>)" >&2
        exit 1
      fi
      local existing="${ALB_ECS_SERVICES["${current_alb}"]:-}"
      if [[ " ${existing} " != *" ${svc_name} "* ]]; then
        ALB_ECS_SERVICES["${current_alb}"]="${existing:+${existing} }${svc_name}"
      fi
    fi
  done < "${CONFIG_FILE}"

  if [[ ${#ALBS_ORDERED[@]} -eq 0 ]]; then
    echo "error: ${CONFIG_FILE} declares no ALBs" >&2
    exit 1
  fi
}

validate_ecs_service() {
  local alb="$1" svc="$2"
  local missing=()
  local field
  for field in cluster container_name container_port target_group_arn; do
    if [[ -z "${CONFIG["${alb}.ecs_service.${svc}.${field}"]:-}" ]]; then
      missing+=("${field}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: ALB '${alb}' ecs_service '${svc}' is missing: ${missing[*]}" >&2
    exit 1
  fi
  local port="${CONFIG["${alb}.ecs_service.${svc}.container_port"]}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
    echo "error: ALB '${alb}' ecs_service '${svc}': container_port must be an integer (got '${port}')" >&2
    exit 1
  fi
}

require_key() {
  local alb="$1" key="$2"
  if [[ -z "${CONFIG["${alb}.${key}"]:-}" ]]; then
    echo "error: ALB '${alb}' is missing required key '${key}'" >&2
    exit 1
  fi
}

validate_alb() {
  local alb="$1"
  require_key "${alb}" scheme
  require_key "${alb}" ip_address_type
  require_key "${alb}" subnets
  require_key "${alb}" security_groups

  local scheme="${CONFIG["${alb}.scheme"]}"
  case "${scheme}" in
    internet-facing|internal) ;;
    *) echo "error: ALB '${alb}': scheme must be 'internet-facing' or 'internal' (got '${scheme}')" >&2; exit 1 ;;
  esac

  local ip_type="${CONFIG["${alb}.ip_address_type"]}"
  case "${ip_type}" in
    ipv4|dualstack) ;;
    *) echo "error: ALB '${alb}': ip_address_type must be 'ipv4' or 'dualstack' (got '${ip_type}')" >&2; exit 1 ;;
  esac
}

# describe_alb <name> — prints "ARN<TAB>DNSName<TAB>ZoneId" or returns 1.
describe_alb() {
  local name="$1"
  "${AWS[@]}" elbv2 describe-load-balancers --names "${name}" \
    --output text \
    --query 'LoadBalancers[0].[LoadBalancerArn,DNSName,CanonicalHostedZoneId]' \
    2>/dev/null
}

# build_tag_args <tags_csv> — emits the --tags args (Key=k,Value=v ...) on
# stdout, space-separated, ready to be word-split into an args array.
build_tag_args() {
  local tags_csv="$1"
  if [[ -z "${tags_csv}" ]]; then return; fi
  local kv k v out=""
  local IFS=','
  for kv in ${tags_csv}; do
    k="${kv%%=*}"
    v="${kv##*=}"
    if [[ -z "${k}" || "${k}" == "${kv}" ]]; then
      echo "error: malformed tag '${kv}' (expected Key=Value)" >&2
      exit 1
    fi
    out+="Key=${k},Value=${v} "
  done
  printf '%s' "${out% }"
}

create_one_alb() {
  local name="$1"
  local scheme="${CONFIG["${name}.scheme"]}"
  local ip_type="${CONFIG["${name}.ip_address_type"]}"
  local subnets_csv="${CONFIG["${name}.subnets"]}"
  local sgs_csv="${CONFIG["${name}.security_groups"]}"
  local tags_csv="${CONFIG["${name}.tags"]:-}"

  local existing
  if existing="$(describe_alb "${name}")"; then
    log "alb ${name}: already exists — reusing"
    printf '%s' "${existing}"
    return
  fi

  local args=(
    elbv2 create-load-balancer
    --name "${name}"
    --type application
    --scheme "${scheme}"
    --ip-address-type "${ip_type}"
    --subnets ${subnets_csv//,/ }
    --security-groups ${sgs_csv//,/ }
  )

  if [[ -n "${tags_csv}" ]]; then
    local tag_args_str
    tag_args_str="$(build_tag_args "${tags_csv}")"
    # shellcheck disable=SC2206
    local tag_args=(${tag_args_str})
    args+=(--tags "${tag_args[@]}")
  fi

  log "alb ${name}: creating (${scheme}, ${ip_type})"
  "${AWS[@]}" "${args[@]}" \
    --no-cli-pager \
    --output text \
    --query 'LoadBalancers[0].[LoadBalancerArn,DNSName,CanonicalHostedZoneId]'
}

delete_one_alb() {
  local name="$1"
  local info arn
  if ! info="$(describe_alb "${name}")"; then
    log "alb ${name}: not found — skipping"
    return
  fi
  arn="${info%%$'\t'*}"
  log "alb ${name}: deleting (${arn})"
  "${AWS[@]}" elbv2 delete-load-balancer \
    --load-balancer-arn "${arn}" \
    --no-cli-pager
}

emit_records_header() {
  local target="$1"
  {
    printf '# Generated by manage-albs.sh on %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# Apply with:\n'
    printf '#   HOSTED_ZONE_ID=<your-zone-id> ./scripts/apply-dns-records.sh <this-file>\n'
    printf '#\n'
  } > "${target}"
}

# emit_records_for_alb <target-file> <name> <dns_name> <zone_id>
emit_records_for_alb() {
  local target="$1" name="$2" alb_dns="$3" zone_id="$4"
  local dns_names_csv="${CONFIG["${name}.dns_names"]:-}"
  local ip_type="${CONFIG["${name}.ip_address_type"]}"

  if [[ -z "${dns_names_csv}" ]]; then
    return
  fi

  # ensure trailing dot on the ALB DNS name for clarity
  local target_dns="${alb_dns}"
  [[ "${target_dns}" != *. ]] && target_dns="${target_dns}."

  {
    printf '\n# %s (%s) -> %s (zone %s)\n' "${name}" "${ip_type}" "${target_dns}" "${zone_id}"
    local d
    local IFS=','
    for d in ${dns_names_csv}; do
      d="$(trim "${d}")"
      [[ -z "${d}" ]] && continue
      [[ "${d}" != *. ]] && d="${d}."
      printf 'alias  A     %s  %s  %s\n' "${d}" "${zone_id}" "${target_dns}"
      if [[ "${ip_type}" == "dualstack" ]]; then
        printf 'alias  AAAA  %s  %s  %s\n' "${d}" "${zone_id}" "${target_dns}"
      fi
    done
  } >> "${target}"
}

emit_service_lb_header() {
  local target="$1"
  {
    printf '# Generated by manage-albs.sh on %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# Apply with:\n'
    printf '#   ./scripts/update-service-alb.sh <this-file>\n'
    printf '#\n'
  } > "${target}"
}

# emit_service_lb_for_alb <target-file> <alb_name>
emit_service_lb_for_alb() {
  local target="$1" alb="$2"
  local svcs="${ALB_ECS_SERVICES["${alb}"]:-}"
  [[ -z "${svcs}" ]] && return

  {
    printf '\n# from ALB %s\n' "${alb}"
    local svc
    for svc in ${svcs}; do
      printf '[%s]\n' "${svc}"
      printf 'cluster=%s\n'           "${CONFIG["${alb}.ecs_service.${svc}.cluster"]}"
      printf 'container_name=%s\n'    "${CONFIG["${alb}.ecs_service.${svc}.container_name"]}"
      printf 'container_port=%s\n'    "${CONFIG["${alb}.ecs_service.${svc}.container_port"]}"
      printf 'target_group_arn=%s\n'  "${CONFIG["${alb}.ecs_service.${svc}.target_group_arn"]}"
      printf '\n'
    done
  } >> "${target}"
}

do_create() {
  local alb svc
  for alb in "${ALBS_ORDERED[@]}"; do
    validate_alb "${alb}"
    for svc in ${ALB_ECS_SERVICES["${alb}"]:-}; do
      validate_ecs_service "${alb}" "${svc}"
    done
  done

  log "config declares ${#ALBS_ORDERED[@]} ALB(s): ${ALBS_ORDERED[*]}"
  if ! confirm "Create (or reuse) these ALBs in ${AWS_REGION}?"; then
    echo "aborted." >&2
    exit 1
  fi

  local records_target="${OUTPUT_RECORDS_FILE}"
  local records_is_tmp=0
  if [[ -z "${records_target}" ]]; then
    records_target="$(mktemp)"
    records_is_tmp=1
  fi
  emit_records_header "${records_target}"

  local svclb_target="${OUTPUT_SERVICE_LB_FILE}"
  local svclb_is_tmp=0
  if [[ -z "${svclb_target}" ]]; then
    svclb_target="$(mktemp)"
    svclb_is_tmp=1
  fi
  emit_service_lb_header "${svclb_target}"

  local any_dns=0 any_svc=0
  for alb in "${ALBS_ORDERED[@]}"; do
    local info arn dns_name zone_id
    info="$(create_one_alb "${alb}")"
    IFS=$'\t' read -r arn dns_name zone_id <<< "${info}"
    log "alb ${alb}: dns=${dns_name} zone=${zone_id}"

    if [[ "${WAIT_FOR_ACTIVE:-0}" == "1" ]]; then
      log "alb ${alb}: waiting for state=active..."
      "${AWS[@]}" elbv2 wait load-balancer-available --load-balancer-arns "${arn}"
      log "alb ${alb}: active"
    fi

    if [[ -n "${CONFIG["${alb}.dns_names"]:-}" ]]; then
      any_dns=1
      emit_records_for_alb "${records_target}" "${alb}" "${dns_name}" "${zone_id}"
    fi

    if [[ -n "${ALB_ECS_SERVICES["${alb}"]:-}" ]]; then
      any_svc=1
      emit_service_lb_for_alb "${svclb_target}" "${alb}"
    fi
  done

  if (( any_dns == 0 )); then
    log "no dns_names declared — skipping DNS records output"
    (( records_is_tmp )) && rm -f "${records_target}"
  elif (( records_is_tmp )); then
    log "DNS records template (no path provided — printed below):"
    cat "${records_target}"
    rm -f "${records_target}"
  else
    log "wrote DNS records template to ${records_target}"
  fi

  if (( any_svc == 0 )); then
    log "no ecs_service.* declared — skipping service-LB output"
    (( svclb_is_tmp )) && rm -f "${svclb_target}"
  elif (( svclb_is_tmp )); then
    log "service-LB template (no path provided — printed below):"
    cat "${svclb_target}"
    rm -f "${svclb_target}"
  else
    log "wrote service-LB template to ${svclb_target}"
  fi

  log "done."
}

do_delete() {
  local alb
  log "config declares ${#ALBS_ORDERED[@]} ALB(s) to delete: ${ALBS_ORDERED[*]}"
  if ! confirm "DELETE these ALBs in ${AWS_REGION}? (their listeners cascade with them; target groups, DNS records, and ECS services are NOT touched)"; then
    echo "aborted." >&2
    exit 1
  fi

  for alb in "${ALBS_ORDERED[@]}"; do
    delete_one_alb "${alb}"
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
