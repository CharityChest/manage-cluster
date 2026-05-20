#!/usr/bin/env bash
#
# apply-listeners.sh — create or update ALB listeners from an INI config.
# Idempotent: each listener is keyed by (alb_name, port). Existing listeners
# are modified in place when they drift from the declared state; missing
# ones are created.
#
# Scope is the **tier-2 listener subset** of the ELBv2 model: HTTP or HTTPS
# protocol; a single default action of type `forward`, `redirect`, or
# `fixed-response`. Listener rules with conditions, OIDC/Cognito auth,
# mTLS, weighted forwards, and multi-cert SNI are intentionally out of
# scope — use Terraform for those.
#
# How traffic reaches an ECS service:
#
#     listener (alb:port)
#        |
#        | --default forward-->  target group ARN
#                                     |
#                                     | --bound by update-service-alb.sh-->
#                                     |
#                                  ECS Fargate service
#
# The `default_target_group_arn` in a `forward` listener must be the same
# ARN you also bind to the service via update-service-alb.sh — that shared
# identifier is the "wiring" between the two scripts. There is no separate
# step.
#
# Usage:
#   ./apply-listeners.sh <config-file>
#
# Config file format (INI-style, one [name] section per listener; the
# section name is freeform and used only for logging — the listener
# identity on AWS is (alb_name, port)):
#
#   [prod-https]
#   alb_name=charity-chest-prod-alb
#   port=443
#   protocol=HTTPS
#   certificate_arn=arn:aws:acm:eu-west-1:123:certificate/abc
#   ssl_policy=ELBSecurityPolicy-TLS13-1-2-2021-06  # optional
#   default_action_type=forward
#   default_target_group_arn=arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/server-tg/xxx
#
#   [prod-http-redirect]
#   alb_name=charity-chest-prod-alb
#   port=80
#   protocol=HTTP
#   default_action_type=redirect
#   redirect_protocol=HTTPS
#   redirect_port=443
#   redirect_status_code=HTTP_301
#   # optional: redirect_host, redirect_path, redirect_query — default to
#   # AWS pass-through placeholders (#{host}, /#{path}, #{query}).
#
#   [stg-503-fallback]
#   alb_name=charity-chest-stg-alb
#   port=80
#   protocol=HTTP
#   default_action_type=fixed-response
#   fixed_status_code=503
#   fixed_content_type=text/plain  # optional, default text/plain
#   fixed_body=down for maintenance  # optional
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       e.g. eu-west-1
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

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

declare -A CONFIG
LISTENERS_ORDERED=()

parse_config() {
  local raw_line line current="" key value line_no=0
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
      LISTENERS_ORDERED+=("${current}")
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

  if [[ ${#LISTENERS_ORDERED[@]} -eq 0 ]]; then
    echo "error: ${CONFIG_FILE} declares no listeners" >&2
    exit 1
  fi
}

validate_listener() {
  local lst="$1"
  local f missing=()
  for f in alb_name port protocol default_action_type; do
    [[ -z "${CONFIG["${lst}.${f}"]:-}" ]] && missing+=("${f}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: listener '${lst}' is missing required keys: ${missing[*]}" >&2
    exit 1
  fi

  local port="${CONFIG["${lst}.port"]}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
    echo "error: listener '${lst}': port must be an integer (got '${port}')" >&2
    exit 1
  fi

  local protocol="${CONFIG["${lst}.protocol"]}"
  case "${protocol}" in
    HTTP|HTTPS) ;;
    *) echo "error: listener '${lst}': protocol must be HTTP or HTTPS (got '${protocol}')" >&2; exit 1 ;;
  esac

  if [[ "${protocol}" == "HTTPS" && -z "${CONFIG["${lst}.certificate_arn"]:-}" ]]; then
    echo "error: listener '${lst}': HTTPS requires certificate_arn" >&2
    exit 1
  fi

  local action="${CONFIG["${lst}.default_action_type"]}"
  case "${action}" in
    forward)
      if [[ -z "${CONFIG["${lst}.default_target_group_arn"]:-}" ]]; then
        echo "error: listener '${lst}': forward requires default_target_group_arn" >&2
        exit 1
      fi
      ;;
    redirect)
      local r rmissing=()
      for r in redirect_protocol redirect_port redirect_status_code; do
        [[ -z "${CONFIG["${lst}.${r}"]:-}" ]] && rmissing+=("${r}")
      done
      if [[ ${#rmissing[@]} -gt 0 ]]; then
        echo "error: listener '${lst}': redirect missing: ${rmissing[*]}" >&2
        exit 1
      fi
      local rport="${CONFIG["${lst}.redirect_port"]}"
      # redirect_port can be a number or a placeholder like #{port}; accept both
      if ! [[ "${rport}" =~ ^[0-9]+$ || "${rport}" == \#\{port\} ]]; then
        echo "error: listener '${lst}': redirect_port must be an integer or '#{port}' (got '${rport}')" >&2
        exit 1
      fi
      ;;
    fixed-response)
      if [[ -z "${CONFIG["${lst}.fixed_status_code"]:-}" ]]; then
        echo "error: listener '${lst}': fixed-response requires fixed_status_code" >&2
        exit 1
      fi
      ;;
    *)
      echo "error: listener '${lst}': default_action_type must be forward|redirect|fixed-response (got '${action}')" >&2
      exit 1
      ;;
  esac
}

# get_alb_arn <name> — prints ARN on stdout, returns 1 if not found.
get_alb_arn() {
  local name="$1" arn
  if ! arn="$("${AWS[@]}" elbv2 describe-load-balancers --names "${name}" \
       --output text --query 'LoadBalancers[0].LoadBalancerArn' 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "${arn}"
}

# The 14 listener fields used for idempotency comparison. AWS CLI text output
# renders JSON null as the literal string "None", so the desired-state helper
# uses "None" as the sentinel for unset fields.
listener_state_fields='Protocol,Certificates[0].CertificateArn,SslPolicy,DefaultActions[0].Type,DefaultActions[0].TargetGroupArn,DefaultActions[0].RedirectConfig.Protocol,DefaultActions[0].RedirectConfig.Port,DefaultActions[0].RedirectConfig.Host,DefaultActions[0].RedirectConfig.Path,DefaultActions[0].RedirectConfig.Query,DefaultActions[0].RedirectConfig.StatusCode,DefaultActions[0].FixedResponseConfig.StatusCode,DefaultActions[0].FixedResponseConfig.ContentType,DefaultActions[0].FixedResponseConfig.MessageBody'

# current_listener <alb_arn> <port> — prints ListenerArn + 14 state fields,
# tab-separated. Empty output if no listener on that port.
current_listener() {
  local alb_arn="$1" port="$2"
  "${AWS[@]}" elbv2 describe-listeners --load-balancer-arn "${alb_arn}" \
    --output text \
    --query "Listeners[?Port==\`${port}\`] | [0].[ListenerArn,${listener_state_fields}]"
}

desired_listener_state() {
  local lst="$1"
  local protocol="${CONFIG["${lst}.protocol"]}"
  local cert="${CONFIG["${lst}.certificate_arn"]:-None}"
  local ssl="${CONFIG["${lst}.ssl_policy"]:-None}"
  local action="${CONFIG["${lst}.default_action_type"]}"
  local tg="None" r_p="None" r_pt="None" r_h="None" r_pa="None" r_q="None" r_sc="None"
  local f_sc="None" f_ct="None" f_b="None"
  case "${action}" in
    forward)
      tg="${CONFIG["${lst}.default_target_group_arn"]}"
      ;;
    redirect)
      r_p="${CONFIG["${lst}.redirect_protocol"]}"
      r_pt="${CONFIG["${lst}.redirect_port"]}"
      r_h="${CONFIG["${lst}.redirect_host"]:-#{host}}"
      r_pa="${CONFIG["${lst}.redirect_path"]:-/#{path}}"
      r_q="${CONFIG["${lst}.redirect_query"]:-#{query}}"
      r_sc="${CONFIG["${lst}.redirect_status_code"]}"
      ;;
    fixed-response)
      f_sc="${CONFIG["${lst}.fixed_status_code"]}"
      f_ct="${CONFIG["${lst}.fixed_content_type"]:-text/plain}"
      f_b="${CONFIG["${lst}.fixed_body"]:-None}"
      ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${protocol}" "${cert}" "${ssl}" "${action}" "${tg}" \
    "${r_p}" "${r_pt}" "${r_h}" "${r_pa}" "${r_q}" "${r_sc}" \
    "${f_sc}" "${f_ct}" "${f_b}"
}

build_default_actions_json() {
  local lst="$1"
  local action="${CONFIG["${lst}.default_action_type"]}"
  case "${action}" in
    forward)
      local tg
      tg="$(json_escape "${CONFIG["${lst}.default_target_group_arn"]}")"
      printf '[{"Type":"forward","TargetGroupArn":"%s"}]' "${tg}"
      ;;
    redirect)
      local p pt h pa q sc
      p="$(json_escape "${CONFIG["${lst}.redirect_protocol"]}")"
      pt="$(json_escape "${CONFIG["${lst}.redirect_port"]}")"
      h="$(json_escape "${CONFIG["${lst}.redirect_host"]:-#{host}}")"
      pa="$(json_escape "${CONFIG["${lst}.redirect_path"]:-/#{path}}")"
      q="$(json_escape "${CONFIG["${lst}.redirect_query"]:-#{query}}")"
      sc="$(json_escape "${CONFIG["${lst}.redirect_status_code"]}")"
      printf '[{"Type":"redirect","RedirectConfig":{"Protocol":"%s","Port":"%s","Host":"%s","Path":"%s","Query":"%s","StatusCode":"%s"}}]' \
        "${p}" "${pt}" "${h}" "${pa}" "${q}" "${sc}"
      ;;
    fixed-response)
      local sc ct b
      sc="$(json_escape "${CONFIG["${lst}.fixed_status_code"]}")"
      ct="$(json_escape "${CONFIG["${lst}.fixed_content_type"]:-text/plain}")"
      b="${CONFIG["${lst}.fixed_body"]:-}"
      if [[ -n "${b}" ]]; then
        b="$(json_escape "${b}")"
        printf '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"%s","ContentType":"%s","MessageBody":"%s"}}]' \
          "${sc}" "${ct}" "${b}"
      else
        printf '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"%s","ContentType":"%s"}}]' \
          "${sc}" "${ct}"
      fi
      ;;
  esac
}

apply_one_listener() {
  local lst="$1"
  local alb_name="${CONFIG["${lst}.alb_name"]}"
  local port="${CONFIG["${lst}.port"]}"
  local protocol="${CONFIG["${lst}.protocol"]}"

  local alb_arn
  if ! alb_arn="$(get_alb_arn "${alb_name}")"; then
    echo "error: listener '${lst}': ALB '${alb_name}' not found in ${AWS_REGION}" >&2
    exit 1
  fi

  local row
  row="$(current_listener "${alb_arn}" "${port}")"

  local common_args=(
    --protocol "${protocol}"
    --port "${port}"
    --default-actions "$(build_default_actions_json "${lst}")"
  )
  if [[ "${protocol}" == "HTTPS" ]]; then
    common_args+=(--certificates "CertificateArn=${CONFIG["${lst}.certificate_arn"]}")
    if [[ -n "${CONFIG["${lst}.ssl_policy"]:-}" ]]; then
      common_args+=(--ssl-policy "${CONFIG["${lst}.ssl_policy"]}")
    fi
  fi

  if [[ -z "${row}" ]]; then
    log "listener ${lst} (${alb_name}:${port}): creating"
    "${AWS[@]}" elbv2 create-listener \
      --load-balancer-arn "${alb_arn}" \
      "${common_args[@]}" \
      --no-cli-pager \
      >/dev/null
    return
  fi

  local listener_arn="${row%%$'\t'*}"
  local current_state="${row#*$'\t'}"
  local desired
  desired="$(desired_listener_state "${lst}")"
  if [[ "${current_state}" == "${desired}" ]]; then
    log "listener ${lst} (${alb_name}:${port}): already matches — skipping"
    return
  fi

  log "listener ${lst} (${alb_name}:${port}): modifying"
  "${AWS[@]}" elbv2 modify-listener \
    --listener-arn "${listener_arn}" \
    "${common_args[@]}" \
    --no-cli-pager \
    >/dev/null
}

main() {
  parse_config
  local lst
  for lst in "${LISTENERS_ORDERED[@]}"; do
    validate_listener "${lst}"
  done

  log "config declares ${#LISTENERS_ORDERED[@]} listener(s): ${LISTENERS_ORDERED[*]}"
  if ! confirm "Apply listeners in ${AWS_REGION}?"; then
    echo "aborted." >&2
    exit 1
  fi

  for lst in "${LISTENERS_ORDERED[@]}"; do
    apply_one_listener "${lst}"
  done

  log "done."
}

main "$@"
