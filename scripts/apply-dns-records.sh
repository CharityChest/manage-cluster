#!/usr/bin/env bash
#
# apply-dns-records.sh — apply a set of upsert/delete changes to a Route 53
# hosted zone. Reads a plain-text records file and submits one
# change-resource-record-sets call.
#
# Idempotent: UPSERT is safe to re-run (Route 53 replaces in place); DELETE
# is pre-checked against current zone state and skipped if the target record
# is already absent.
#
# Usage:
#   ./apply-dns-records.sh <records-file>
#
# Records file format (one record per non-comment line):
#
#   # Lines starting with '#' and blank lines are ignored.
#   # Columns: ACTION  TYPE  NAME                  TTL  VALUE[|VALUE...]
#   upsert  A      api.example.com.       300  192.0.2.1
#   upsert  A      multi.example.com.     300  192.0.2.1|192.0.2.2
#   upsert  CNAME  www.example.com.       300  example.com.
#   upsert  TXT    _acme.example.com.     300  "verification-token"
#   delete  A      old.example.com.
#   delete  CNAME  legacy.example.com.
#
# Alias records (e.g. pointing at an ALB/NLB/CloudFront) use a different
# layout — no TTL, no value list, instead a target DNS name + the target's
# canonical hosted zone ID:
#
#   # Columns: alias  TYPE  NAME                  TARGET_ZONE_ID    TARGET_DNS_NAME  [EVAL_HEALTH]
#   alias   A     api.example.com.       Z32O12XQLNTSW2    dualstack.my-alb-1234.eu-west-1.elb.amazonaws.com.
#   alias   A     www.example.com.       Z2FDTNDATAQYW2    d111111abcdef8.cloudfront.net.                       true
#
# - NAME must end with a trailing dot (FQDN).
# - For UPSERT, multi-value record sets use '|' as the value separator.
# - For TXT VALUE, include the surrounding double quotes per Route 53's wire
#   format, e.g. '"verification-token"'.
# - For DELETE, TTL/VALUE columns are not required — current zone state is
#   used to build the change. DELETE works on alias records too.
# - For ALIAS, TARGET_ZONE_ID is the AWS-managed hosted zone of the target
#   resource (NOT your own HOSTED_ZONE_ID). Look these up with:
#
#       # ALB / NLB:
#       aws elbv2 describe-load-balancers --names <lb-name> \
#         --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text
#
#       # CloudFront is always Z2FDTNDATAQYW2.
#
#   For ALB dual-stack (IPv4+IPv6) aliases, prefix the DNSName with
#   'dualstack.'. EVAL_HEALTH defaults to 'false'.
#
# Required env vars (or pass via a .env file alongside this script):
#   AWS_REGION       passed through to the AWS CLI (Route 53 is global, but
#                    this matches the other scripts in this repo)
#   HOSTED_ZONE_ID   Route 53 hosted zone identifier (e.g. Z3ABCXYZ)
# Optional:
#   AWS_PROFILE      passed through to the AWS CLI
#   WAIT_FOR_SYNC=1  block until the change reaches INSYNC (usually <1 min)
#   ASSUME_YES=1     skip the confirmation prompt (useful for cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <records-file>" >&2
  exit 2
fi

RECORDS_FILE="$1"

: "${AWS_REGION:?AWS_REGION is required}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID is required}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found in PATH" >&2
  exit 127
fi

if [[ ! -r "${RECORDS_FILE}" ]]; then
  echo "error: records file not readable: ${RECORDS_FILE}" >&2
  exit 1
fi

AWS=(aws --region "${AWS_REGION}")

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "Apply $1 change(s) to hosted zone ${HOSTED_ZONE_ID}? [y/N] " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Escape a string for embedding inside a JSON string literal. Handles the
# two characters that matter for typical DNS values: backslash and double
# quote. Control characters in record values are extremely unusual and not
# supported here.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# fetch_record_set <name> <type> — prints the matching ResourceRecordSet
# JSON object, or nothing if the record does not exist in the zone.
fetch_record_set() {
  local name="$1" type="$2" result
  result="$("${AWS[@]}" route53 list-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --start-record-name "${name}" \
    --start-record-type "${type}" \
    --max-items 10 \
    --output json \
    --query "ResourceRecordSets[?Name=='${name}' && Type=='${type}'] | [0]")"
  if [[ -z "${result}" || "${result}" == "null" ]]; then
    return
  fi
  printf '%s' "${result}"
}

# build_upsert_change <type> <name> <ttl> <values_pipe>
# Emits a single Change JSON object on stdout.
build_upsert_change() {
  local type="$1" name="$2" ttl="$3" values_pipe="$4"
  local records_json="" first=1 v escaped
  local IFS='|'
  # shellcheck disable=SC2206
  local values=(${values_pipe})
  for v in "${values[@]}"; do
    escaped="$(json_escape "${v}")"
    if (( first )); then
      records_json+="{\"Value\":\"${escaped}\"}"
      first=0
    else
      records_json+=",{\"Value\":\"${escaped}\"}"
    fi
  done
  printf '{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"%s","TTL":%s,"ResourceRecords":[%s]}}' \
    "$(json_escape "${name}")" "${type}" "${ttl}" "${records_json}"
}

# build_alias_change <type> <name> <target_zone_id> <target_dns_name> <evaluate_health>
# Emits an UPSERT Change JSON object for an alias record. No TTL, no
# ResourceRecords — alias records use Route 53's AliasTarget structure.
build_alias_change() {
  local type="$1" name="$2" target_zone_id="$3" target_dns_name="$4" evaluate_health="$5"
  printf '{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"%s","AliasTarget":{"HostedZoneId":"%s","DNSName":"%s","EvaluateTargetHealth":%s}}}' \
    "$(json_escape "${name}")" "${type}" "$(json_escape "${target_zone_id}")" \
    "$(json_escape "${target_dns_name}")" "${evaluate_health}"
}

# build_delete_change <type> <name>
# Emits a Change JSON object on stdout, or nothing if the record is absent.
# Route 53 DELETE requires the exact current ResourceRecordSet, so we inline
# whatever's currently in the zone.
build_delete_change() {
  local type="$1" name="$2" rrset
  rrset="$(fetch_record_set "${name}" "${type}")"
  if [[ -z "${rrset}" ]]; then
    return
  fi
  printf '{"Action":"DELETE","ResourceRecordSet":%s}' "${rrset}"
}

assert_zone_exists() {
  # Stdout is suppressed (we only care that the call succeeded), but stderr
  # is intentionally NOT redirected — when this fails, AWS's own error
  # (AccessDenied, NoSuchHostedZone, expired creds, ...) is what the
  # operator actually needs to see.
  if ! "${AWS[@]}" route53 get-hosted-zone --id "${HOSTED_ZONE_ID}" \
       --output text --query 'HostedZone.Id' >/dev/null; then
    {
      echo "error: hosted zone ${HOSTED_ZONE_ID} not found or not accessible"
      echo "  - check the account / profile your credentials point to:"
      echo "      aws sts get-caller-identity"
      echo "  - list zones visible to these credentials:"
      echo "      aws route53 list-hosted-zones --query 'HostedZones[].[Id,Name]' --output table"
    } >&2
    exit 1
  fi
}

main() {
  assert_zone_exists

  local changes=()
  local upserts=0 deletes=0 skipped=0 line_no=0
  local raw_line line action type name ttl values_pipe

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line_no=$(( line_no + 1 ))
    line="${raw_line%$'\r'}"

    if [[ "${line}" =~ ^[[:space:]]*$ ]]; then continue; fi
    if [[ "${line}" =~ ^[[:space:]]*# ]]; then continue; fi

    action=""; type=""; name=""; ttl=""; values_pipe=""
    read -r action type name ttl values_pipe <<< "${line}" || true

    if [[ -z "${action}" || -z "${type}" || -z "${name}" ]]; then
      echo "error: ${RECORDS_FILE}:${line_no}: expected at least ACTION TYPE NAME" >&2
      exit 1
    fi

    action="${action,,}"
    type="${type^^}"

    case "${action}" in
      upsert)
        if [[ -z "${ttl}" || -z "${values_pipe}" ]]; then
          echo "error: ${RECORDS_FILE}:${line_no}: upsert requires TTL and VALUE" >&2
          exit 1
        fi
        if ! [[ "${ttl}" =~ ^[0-9]+$ ]]; then
          echo "error: ${RECORDS_FILE}:${line_no}: TTL must be an integer (got '${ttl}')" >&2
          exit 1
        fi
        changes+=("$(build_upsert_change "${type}" "${name}" "${ttl}" "${values_pipe}")")
        upserts=$(( upserts + 1 ))
        log "upsert ${type} ${name} (ttl=${ttl}, values=${values_pipe})"
        ;;
      alias)
        # For alias rows, columns 4+ are: TARGET_ZONE_ID TARGET_DNS_NAME [EVAL_HEALTH]
        # Reuse the parsed fields: ttl holds TARGET_ZONE_ID, values_pipe holds the rest.
        if [[ -z "${ttl}" || -z "${values_pipe}" ]]; then
          echo "error: ${RECORDS_FILE}:${line_no}: alias requires TARGET_ZONE_ID and TARGET_DNS_NAME" >&2
          exit 1
        fi
        local alias_zone_id="${ttl}"
        local alias_dns_name eval_health
        read -r alias_dns_name eval_health <<< "${values_pipe}" || true
        if [[ -z "${alias_dns_name}" ]]; then
          echo "error: ${RECORDS_FILE}:${line_no}: alias requires TARGET_DNS_NAME" >&2
          exit 1
        fi
        eval_health="${eval_health:-false}"
        eval_health="${eval_health,,}"
        if [[ "${eval_health}" != "true" && "${eval_health}" != "false" ]]; then
          echo "error: ${RECORDS_FILE}:${line_no}: EVAL_HEALTH must be true or false (got '${eval_health}')" >&2
          exit 1
        fi
        if [[ "${type}" != "A" && "${type}" != "AAAA" ]]; then
          echo "error: ${RECORDS_FILE}:${line_no}: alias TYPE must be A or AAAA (got '${type}')" >&2
          exit 1
        fi
        changes+=("$(build_alias_change "${type}" "${name}" "${alias_zone_id}" "${alias_dns_name}" "${eval_health}")")
        upserts=$(( upserts + 1 ))
        log "alias ${type} ${name} -> ${alias_dns_name} (zone=${alias_zone_id}, evalHealth=${eval_health})"
        ;;
      delete)
        local change
        change="$(build_delete_change "${type}" "${name}")"
        if [[ -z "${change}" ]]; then
          log "delete ${type} ${name}: not present — skipping"
          skipped=$(( skipped + 1 ))
        else
          changes+=("${change}")
          deletes=$(( deletes + 1 ))
          log "delete ${type} ${name}"
        fi
        ;;
      *)
        echo "error: ${RECORDS_FILE}:${line_no}: unknown action '${action}' (expected upsert|alias|delete)" >&2
        exit 1
        ;;
    esac
  done < "${RECORDS_FILE}"

  local total=$(( upserts + deletes ))
  if (( total == 0 )); then
    log "no changes to apply (${skipped} delete(s) skipped: records already absent)"
    return
  fi

  log "prepared ${total} change(s): ${upserts} upsert, ${deletes} delete, ${skipped} skipped"

  if ! confirm "${total}"; then
    echo "aborted." >&2
    exit 1
  fi

  local joined batch
  joined="$(printf '%s,' "${changes[@]}")"
  joined="${joined%,}"
  batch="{\"Changes\":[${joined}]}"

  local change_id
  change_id="$("${AWS[@]}" route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "${batch}" \
    --no-cli-pager \
    --output text \
    --query 'ChangeInfo.Id')"
  log "submitted change ${change_id}"

  if [[ "${WAIT_FOR_SYNC:-0}" == "1" ]]; then
    log "waiting for change to reach INSYNC..."
    "${AWS[@]}" route53 wait resource-record-sets-changed --id "${change_id}"
    log "change ${change_id}: INSYNC"
  fi

  log "done."
}

main "$@"
