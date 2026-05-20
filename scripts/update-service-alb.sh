#!/usr/bin/env bash
#
# update-service-alb.sh — update the load balancer association on a set of
# ECS Fargate services. For each service in the config file, replaces the
# current `loadBalancers` config (atomic remove+add via one update-service
# call) — or clears it entirely.
#
# AWS allows mutating `loadBalancers` on a live ECS service since 2022. The
# service must be in a stable state, and on Fargate platform version 1.4.0+
# (the default since 2020). ECS automatically rolls out a new deployment
# when the load balancer config changes.
#
# Idempotent: if a service's current `loadBalancers` already matches the
# desired state (or is already empty when `clear=true`), the update-service
# call is skipped.
#
# Usage:
#   ./update-service-alb.sh <config-file>
#
# Config file format (INI-style, one `[service-name]` section per service):
#
#   # Replace existing LB config with this one (or add it, if none).
#   [charity-chest-server]
#   cluster=charity-chest-prod
#   target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/server-tg/abc
#   container_name=server
#   container_port=8080
#
#   # Remove all LB associations from this service.
#   [charity-chest-webapp]
#   cluster=charity-chest-prod
#   clear=true
#
#   # Surgically detach ONE target group (by ARN) while leaving any other
#   # loadBalancers entries on the service untouched.
#   [charity-chest-multi]
#   cluster=charity-chest-prod
#   remove_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/old-tg/xyz
#
#   # Append a new target group to the service, KEEPING all existing
#   # loadBalancers entries. Idempotent: skipped if the ARN is already
#   # attached.
#   [charity-chest-extend]
#   cluster=charity-chest-prod
#   add_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/new-tg/uvw
#   container_name=server
#   container_port=8080
#
# Each section requires `cluster`. Exactly one of these mode keys must be set:
#   - target_group_arn (+ container_name + container_port): replace the
#     whole loadBalancers array with this single entry.
#   - clear=true: empty the loadBalancers array.
#   - add_target_group_arn (+ container_name + container_port): append this
#     entry to the existing loadBalancers array, keeping everything that's
#     already there.
#   - remove_target_group_arn=<arn>: keep all existing entries except the
#     one whose targetGroupArn equals <arn>.
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION             e.g. eu-west-1
# Optional:
#   AWS_PROFILE            passed through to the AWS CLI
#   ASSUME_YES=1           skip the confirmation prompt
#   FORCE_NEW_DEPLOYMENT=1 also pass --force-new-deployment (ECS already
#                          triggers a deployment on LB changes; this only
#                          helps when the change is a no-op being re-run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <config-file>" >&2
  exit 2
fi

CONFIG_FILE="$1"

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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

declare -A CONFIG
SERVICES_ORDERED=()

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
      SERVICES_ORDERED+=("${current}")
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

  if [[ ${#SERVICES_ORDERED[@]} -eq 0 ]]; then
    echo "error: ${CONFIG_FILE} declares no services" >&2
    exit 1
  fi
}

# mode_for_service <svc> — prints one of: replace | clear | add | remove
# Based on which mode key is present. The caller must have already validated
# that exactly one mode is set.
mode_for_service() {
  local svc="$1"
  local tg="${CONFIG["${svc}.target_group_arn"]:-}"
  local clear="${CONFIG["${svc}.clear"]:-false}"
  local add="${CONFIG["${svc}.add_target_group_arn"]:-}"
  local rem="${CONFIG["${svc}.remove_target_group_arn"]:-}"
  if [[ -n "${tg}" ]]; then printf 'replace'; return; fi
  if [[ "${clear}" == "true" ]]; then printf 'clear'; return; fi
  if [[ -n "${add}" ]]; then printf 'add'; return; fi
  if [[ -n "${rem}" ]]; then printf 'remove'; return; fi
  printf 'unset'
}

validate_service() {
  local svc="$1"
  if [[ -z "${CONFIG["${svc}.cluster"]:-}" ]]; then
    echo "error: service '${svc}' is missing required key 'cluster'" >&2
    exit 1
  fi

  local modes=()
  [[ -n "${CONFIG["${svc}.target_group_arn"]:-}" ]] && modes+=(target_group_arn)
  [[ "${CONFIG["${svc}.clear"]:-false}" == "true" ]] && modes+=(clear)
  [[ -n "${CONFIG["${svc}.add_target_group_arn"]:-}" ]] && modes+=(add_target_group_arn)
  [[ -n "${CONFIG["${svc}.remove_target_group_arn"]:-}" ]] && modes+=(remove_target_group_arn)

  if [[ ${#modes[@]} -eq 0 ]]; then
    echo "error: service '${svc}': set one of target_group_arn, clear=true, add_target_group_arn, or remove_target_group_arn" >&2
    exit 1
  fi
  if [[ ${#modes[@]} -gt 1 ]]; then
    echo "error: service '${svc}': conflicting modes set (${modes[*]}) — pick exactly one" >&2
    exit 1
  fi

  local mode
  mode="$(mode_for_service "${svc}")"
  if [[ "${mode}" == "replace" || "${mode}" == "add" ]]; then
    local missing=()
    [[ -z "${CONFIG["${svc}.container_name"]:-}" ]] && missing+=(container_name)
    [[ -z "${CONFIG["${svc}.container_port"]:-}" ]] && missing+=(container_port)
    if [[ ${#missing[@]} -gt 0 ]]; then
      local mode_key="target_group_arn"
      [[ "${mode}" == "add" ]] && mode_key="add_target_group_arn"
      echo "error: service '${svc}' has ${mode_key} but is missing: ${missing[*]}" >&2
      exit 1
    fi
    local port="${CONFIG["${svc}.container_port"]}"
    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
      echo "error: service '${svc}': container_port must be an integer (got '${port}')" >&2
      exit 1
    fi
  fi
}

current_lb_for_service() {
  local cluster="$1" service="$2"
  "${AWS[@]}" ecs describe-services \
    --cluster "${cluster}" \
    --services "${service}" \
    --output text \
    --query 'services[0].loadBalancers[].[targetGroupArn,containerName,containerPort]'
}

update_one_service() {
  local svc="$1"
  local cluster="${CONFIG["${svc}.cluster"]}"
  local mode
  mode="$(mode_for_service "${svc}")"

  local extra_args=()
  if [[ "${FORCE_NEW_DEPLOYMENT:-0}" == "1" ]]; then
    extra_args+=(--force-new-deployment)
  fi

  case "${mode}" in
    clear)
      local current
      current="$(current_lb_for_service "${cluster}" "${svc}")"
      if [[ -z "${current}" ]]; then
        log "service ${svc}: loadBalancers already empty — skipping"
        return
      fi
      log "service ${svc}: clearing loadBalancers"
      "${AWS[@]}" ecs update-service \
        --cluster "${cluster}" \
        --service "${svc}" \
        --load-balancers '[]' \
        ${extra_args[@]+"${extra_args[@]}"} \
        --no-cli-pager \
        >/dev/null
      ;;

    replace)
      local tg="${CONFIG["${svc}.target_group_arn"]}"
      local cn="${CONFIG["${svc}.container_name"]}"
      local cp="${CONFIG["${svc}.container_port"]}"
      local current desired
      current="$(current_lb_for_service "${cluster}" "${svc}")"
      desired="${tg}"$'\t'"${cn}"$'\t'"${cp}"
      if [[ "${current}" == "${desired}" ]]; then
        log "service ${svc}: loadBalancers already matches — skipping"
        return
      fi
      log "service ${svc}: setting loadBalancers -> ${cn}:${cp} via ${tg##*/}"
      local lb_json
      lb_json="[{\"targetGroupArn\":\"${tg}\",\"containerName\":\"${cn}\",\"containerPort\":${cp}}]"
      "${AWS[@]}" ecs update-service \
        --cluster "${cluster}" \
        --service "${svc}" \
        --load-balancers "${lb_json}" \
        ${extra_args[@]+"${extra_args[@]}"} \
        --no-cli-pager \
        >/dev/null
      ;;

    add)
      local add_arn="${CONFIG["${svc}.add_target_group_arn"]}"
      local cn="${CONFIG["${svc}.container_name"]}"
      local cp="${CONFIG["${svc}.container_port"]}"
      # Idempotency: a given target group can only attach once per service,
      # so check by ARN alone.
      local matched
      matched="$("${AWS[@]}" ecs describe-services \
        --cluster "${cluster}" \
        --services "${svc}" \
        --output text \
        --query "length(services[0].loadBalancers[?targetGroupArn=='${add_arn}'])")"
      if [[ "${matched}" != "0" ]]; then
        log "service ${svc}: target group ${add_arn##*/} already attached — skipping"
        return
      fi
      # Splice the new entry into the existing JSON array. Stripping the
      # trailing `]` and appending `,<entry>]` works regardless of pretty-
      # printing because JSON is whitespace-insensitive. This preserves any
      # fields ECS may return that we don't model explicitly.
      local current_json
      current_json="$("${AWS[@]}" ecs describe-services \
        --cluster "${cluster}" \
        --services "${svc}" \
        --output json \
        --query 'services[0].loadBalancers')"
      local new_entry
      new_entry="{\"targetGroupArn\":\"${add_arn}\",\"containerName\":\"${cn}\",\"containerPort\":${cp}}"
      local combined
      if [[ -z "${current_json}" || "${current_json}" == "null" || "${current_json}" == "[]" ]]; then
        combined="[${new_entry}]"
      else
        combined="${current_json%]},${new_entry}]"
      fi
      log "service ${svc}: appending ${add_arn##*/} on ${cn}:${cp}"
      "${AWS[@]}" ecs update-service \
        --cluster "${cluster}" \
        --service "${svc}" \
        --load-balancers "${combined}" \
        ${extra_args[@]+"${extra_args[@]}"} \
        --no-cli-pager \
        >/dev/null
      ;;

    remove)
      local remove_arn="${CONFIG["${svc}.remove_target_group_arn"]}"
      local total matched
      read -r total matched <<< "$("${AWS[@]}" ecs describe-services \
        --cluster "${cluster}" \
        --services "${svc}" \
        --output text \
        --query "[length(services[0].loadBalancers), length(services[0].loadBalancers[?targetGroupArn=='${remove_arn}'])]")"
      if [[ "${matched}" == "0" ]]; then
        log "service ${svc}: target group ${remove_arn##*/} not attached — skipping"
        return
      fi
      # JMESPath filter emits the kept entries as a JSON array under --output
      # json — pass it straight back into update-service.
      local kept_json
      kept_json="$("${AWS[@]}" ecs describe-services \
        --cluster "${cluster}" \
        --services "${svc}" \
        --output json \
        --query "services[0].loadBalancers[?targetGroupArn!='${remove_arn}']")"
      log "service ${svc}: detaching ${remove_arn##*/} (keeping $(( total - matched )) other LB(s))"
      "${AWS[@]}" ecs update-service \
        --cluster "${cluster}" \
        --service "${svc}" \
        --load-balancers "${kept_json}" \
        ${extra_args[@]+"${extra_args[@]}"} \
        --no-cli-pager \
        >/dev/null
      ;;

    *)
      echo "error: service '${svc}': unknown mode (validation bug)" >&2
      exit 1
      ;;
  esac
}

main() {
  parse_config
  local svc
  for svc in "${SERVICES_ORDERED[@]}"; do
    validate_service "${svc}"
  done

  log "config declares ${#SERVICES_ORDERED[@]} service(s): ${SERVICES_ORDERED[*]}"
  if ! confirm "Update loadBalancers on these ECS services in ${AWS_REGION}? (will trigger a new deployment for each change)"; then
    echo "aborted." >&2
    exit 1
  fi

  for svc in "${SERVICES_ORDERED[@]}"; do
    update_one_service "${svc}"
  done

  log "done."
}

main "$@"
