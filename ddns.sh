#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
VERSION="0.1.2"

PROVIDER=""
ZONE=""
RR=""
INTERVAL="300"
RECORD_TYPE="A"
TTL=""
PROXIED="false"
ONCE="false"
IP_SOURCES=""
DEBUG="false"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_API_KEY="${CF_API_KEY:-}"
CF_API_EMAIL="${CF_API_EMAIL:-}"
ALI_ACCESS_KEY_ID="${ALI_ACCESS_KEY_ID:-}"
ALI_ACCESS_KEY_SECRET="${ALI_ACCESS_KEY_SECRET:-}"

usage() {
  cat <<'USAGE'
Usage:
  ddns.sh --provider cloudflare|aliyun --zone example.com --rr home --interval 300 [options]

Required:
  --provider    DNS provider: cloudflare | aliyun
  --zone        Root zone, e.g. example.com
  --rr          Host record, e.g. @ | www | home.lab
  --interval    Poll interval in seconds

Optional:
  --type        Record type: A | AAAA (default: A)
  --ttl         TTL in seconds (default: 120 for Cloudflare, 600 for Aliyun)
  --proxied     Cloudflare only: true | false (default: false)
  --once        Run once and exit
  --ip-sources  Comma-separated custom IP endpoints
  --cf-token    Cloudflare API token (prefer env CF_API_TOKEN)
  --cf-key      Cloudflare Global API key (fallback auth)
  --cf-email    Cloudflare account email (required with --cf-key)
  --ali-ak      Alibaba Cloud AccessKey ID
  --ali-sk      Alibaba Cloud AccessKey Secret
  --debug       Verbose logging
  -h, --help    Show this help

Recommended credential passing:
  CF_API_TOKEN=xxx bash ddns.sh --provider cloudflare --zone example.com --rr home
  ALI_ACCESS_KEY_ID=xxx ALI_ACCESS_KEY_SECRET=yyy bash ddns.sh --provider aliyun --zone example.com --rr home
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

debug() {
  if [[ "$DEBUG" == "true" ]]; then
    log "DEBUG: $*"
  fi
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

urlencode() {
  local s="${1:-}"
  local length=${#s}
  local out=""
  local i c hex
  for ((i=0; i<length; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ') out+='%20' ;;
      *)
        printf -v hex '%%%02X' "'${c}"
        out+="$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

json_get() {
  local expr="$1"
  if has_cmd jq; then
    jq -r "$expr"
  elif has_cmd python3; then
    python3 -c 'import sys,json; data=json.load(sys.stdin); expr=sys.argv[1];

def get(obj, expr):
    cur=obj
    for part in expr.split("."):
        if part == "":
            continue
        while True:
            if "[" in part and part.endswith("]"):
                name, idx = part[:-1].split("[",1)
                if name:
                    cur = cur[name]
                cur = cur[int(idx)]
                break
            else:
                cur = cur[part]
                break
    return cur

try:
    v=get(data, expr)
    if isinstance(v, bool):
        print(str(v).lower())
    elif v is None:
        print("")
    elif isinstance(v, (dict,list)):
        print(json.dumps(v, ensure_ascii=False))
    else:
        print(v)
except Exception:
    sys.exit(1)
' "$expr"
  else
    die "Need jq or python3 to parse JSON"
  fi
}

json_bool_success() {
  local body="$1"
  if has_cmd jq; then
    jq -e '.success == true' >/dev/null 2>&1 <<<"$body"
  elif has_cmd python3; then
    python3 - <<'PY' <<<"$body"
import sys,json
try:
    data=json.load(sys.stdin)
    sys.exit(0 if data.get('success') is True else 1)
except Exception:
    sys.exit(1)
PY
  else
    grep -q '"success"[[:space:]]*:[[:space:]]*true' <<<"$body"
  fi
}

validate_ip() {
  local ip="$1"
  local type="$2"
  if [[ "$type" == "A" ]]; then
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<<"$ip"
    for n in "$a" "$b" "$c" "$d"; do
      ((n >= 0 && n <= 255)) || return 1
    done
    return 0
  fi

  if [[ "$type" == "AAAA" ]]; then
    if has_cmd python3; then
      python3 - "$ip" <<'PY'
import ipaddress,sys
try:
    ipaddress.IPv6Address(sys.argv[1])
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
      return $?
    fi
    [[ "$ip" == *:* ]]
    return $?
  fi

  return 1
}

get_default_ip_sources() {
  if [[ "$RECORD_TYPE" == "AAAA" ]]; then
    printf '%s
'       "https://ifconfig.me/ip"       "https://api6.ipify.org"       "https://ipv6.icanhazip.com"
  else
    printf '%s
'       "https://ifconfig.me/ip"       "https://api.ipify.org"       "https://ipv4.icanhazip.com"
  fi
}

detect_public_ip() {
  local src ip
  local -a sources=()

  if [[ "$RECORD_TYPE" == "A" ]]; then
    debug "Trying IP source: curl -4 ifconfig.me"
    if ip=$(curl -4 -fsS --max-time 10 ifconfig.me 2>/dev/null | tr -d '[:space:]'); then
      if validate_ip "$ip" "$RECORD_TYPE"; then
        printf '%s
' "$ip"
        return 0
      fi
    fi
  elif [[ "$RECORD_TYPE" == "AAAA" ]]; then
    debug "Trying IP source: curl -6 ifconfig.me"
    if ip=$(curl -6 -fsS --max-time 10 ifconfig.me 2>/dev/null | tr -d '[:space:]'); then
      if validate_ip "$ip" "$RECORD_TYPE"; then
        printf '%s
' "$ip"
        return 0
      fi
    fi
  fi

  if [[ -n "$IP_SOURCES" ]]; then
    mapfile -t sources < <(tr ',' '
' <<<"$IP_SOURCES")
  else
    mapfile -t sources < <(get_default_ip_sources)
  fi

  for src in "${sources[@]}"; do
    [[ -n "$src" ]] || continue
    debug "Trying IP source: $src"
    if ip=$(curl -fsS --max-time 10 "$src" 2>/dev/null | tr -d '[:space:]'); then
      if validate_ip "$ip" "$RECORD_TYPE"; then
        printf '%s
' "$ip"
        return 0
      fi
    fi
  done
  return 1
}

require_args() {
  has_cmd curl || die "curl is required"
  if ! has_cmd jq && ! has_cmd python3; then
    die "Need jq or python3 to parse API JSON"
  fi

  [[ -n "$PROVIDER" ]] || die "--provider is required"
  [[ -n "$ZONE" ]] || die "--zone is required"
  [[ -n "$RR" ]] || die "--rr is required"
  [[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "--interval must be an integer"
  [[ "$RECORD_TYPE" == "A" || "$RECORD_TYPE" == "AAAA" ]] || die "--type must be A or AAAA"

  if [[ -z "$TTL" ]]; then
    case "$PROVIDER" in
      cloudflare) TTL="120" ;;
      aliyun) TTL="600" ;;
    esac
  fi
  [[ "$TTL" =~ ^[0-9]+$ ]] || die "--ttl must be an integer"

  case "$PROVIDER" in
    cloudflare)
      if [[ -z "$CF_API_TOKEN" && ( -z "$CF_API_KEY" || -z "$CF_API_EMAIL" ) ]]; then
        die "Cloudflare requires CF_API_TOKEN or (--cf-key + --cf-email)"
      fi
      ;;
    aliyun)
      has_cmd openssl || die "Aliyun mode requires openssl"
      [[ -n "$ALI_ACCESS_KEY_ID" ]] || die "Aliyun requires ALI_ACCESS_KEY_ID or --ali-ak"
      [[ -n "$ALI_ACCESS_KEY_SECRET" ]] || die "Aliyun requires ALI_ACCESS_KEY_SECRET or --ali-sk"
      if [[ "$TTL" =~ ^[0-9]+$ ]] && (( TTL < 600 )); then
        log "WARN: Aliyun commonly requires TTL >= 600 on many editions; current TTL=${TTL} may fail on create/update"
      fi
      ;;
    *) die "Unsupported provider: $PROVIDER" ;;
  esac
}

full_record_name() {
  if [[ "$RR" == "@" ]]; then
    printf '%s' "$ZONE"
  else
    printf '%s.%s' "$RR" "$ZONE"
  fi
}

cf_auth_args() {
  if [[ -n "$CF_API_TOKEN" ]]; then
    printf '%s\n' \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json"
  else
    printf '%s\n' \
      -H "X-Auth-Key: $CF_API_KEY" \
      -H "X-Auth-Email: $CF_API_EMAIL" \
      -H "Content-Type: application/json"
  fi
}

cf_api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local -a args
  mapfile -t args < <(cf_auth_args)
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "$url" "${args[@]}" --data "$data"
  else
    curl -fsS -X "$method" "$url" "${args[@]}"
  fi
}

cf_get_zone_id() {
  local body zone_id
  body=$(cf_api GET "https://api.cloudflare.com/client/v4/zones?name=$(urlencode "$ZONE")&status=active&match=all") || return 1
  json_bool_success "$body" || {
    log "Cloudflare zone query failed: $body"
    return 1
  }
  zone_id=$(json_get 'result[0].id' <<<"$body" 2>/dev/null || true)
  [[ -n "$zone_id" && "$zone_id" != "null" ]] || return 1
  printf '%s' "$zone_id"
}

cf_get_record() {
  local zone_id="$1"
  local name
  name=$(full_record_name)
  cf_api GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=$(urlencode "$RECORD_TYPE")&name.exact=$(urlencode "$name")&match=all&per_page=1"
}

cf_upsert_record() {
  local current_ip="$1"
  local zone_id record_body record_id remote_ip payload name body success

  zone_id=$(cf_get_zone_id) || die "Cloudflare zone not found or not active: $ZONE"
  record_body=$(cf_get_record "$zone_id") || die "Cloudflare record query failed"
  json_bool_success "$record_body" || die "Cloudflare record query returned error: $record_body"

  record_id=$(json_get 'result[0].id' <<<"$record_body" 2>/dev/null || true)
  remote_ip=$(json_get 'result[0].content' <<<"$record_body" 2>/dev/null || true)
  name=$(full_record_name)

  if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    if [[ "$remote_ip" == "$current_ip" ]]; then
      log "Cloudflare: no change, ${name} already -> ${current_ip}"
      return 0
    fi

    payload=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
      "$RECORD_TYPE" "$name" "$current_ip" "$TTL" "$PROXIED")
    body=$(cf_api PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" "$payload") || die "Cloudflare update request failed"
    json_bool_success "$body" || die "Cloudflare update failed: $body"
    log "Cloudflare: updated ${name} -> ${current_ip}"
  else
    payload=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
      "$RECORD_TYPE" "$name" "$current_ip" "$TTL" "$PROXIED")
    body=$(cf_api POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" "$payload") || die "Cloudflare create request failed"
    json_bool_success "$body" || die "Cloudflare create failed: $body"
    log "Cloudflare: created ${name} -> ${current_ip}"
  fi
}

ali_percent_encode() {
  local value="${1:-}"
  urlencode "$value" | sed -e 's/+/%20/g' -e 's/*/%2A/g' -e 's/%7E/~/g'
}

ali_make_nonce() {
  if has_cmd uuidgen; then
    uuidgen
  elif has_cmd python3; then
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  else
    printf '%s-%s' "$(date +%s)" "$RANDOM"
  fi
}

ali_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ali_sign_query() {
  local canonical="$1"
  local string_to_sign signature
  string_to_sign="GET&%2F&$(ali_percent_encode "$canonical")"
  debug "Aliyun stringToSign: $string_to_sign"
  signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha1 -hmac "${ALI_ACCESS_KEY_SECRET}&" -binary | openssl base64 -A)
  printf '%s' "$signature"
}

ali_common_params() {
  cat <<EOF2
AccessKeyId=${ALI_ACCESS_KEY_ID}
Format=JSON
SignatureMethod=HMAC-SHA1
SignatureNonce=$(ali_make_nonce)
SignatureVersion=1.0
Timestamp=$(ali_timestamp)
Version=2015-01-09
EOF2
}

ali_build_query() {
  local extra="$1"
  local line key value
  {
    ali_common_params
    printf '%s
' "$extra"
  } | while IFS= read -r line; do
    [[ -n "$line" && "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    printf '%s=%s
' "$(ali_percent_encode "$key")" "$(ali_percent_encode "$value")"
  done | LC_ALL=C sort | paste -sd'&' -
}


ali_api() {
  local extra="$1"
  local canonical signature final_query url resp body status
  canonical=$(ali_build_query "$extra")
  signature=$(ali_sign_query "$canonical")
  final_query="${canonical}&Signature=$(ali_percent_encode "$signature")"
  url="https://alidns.aliyuncs.com/?${final_query}"
  debug "Aliyun URL: $url"

  resp=$(curl -sS -w $'
__HTTP_STATUS__:%{http_code}' "$url") || {
    log "Aliyun request transport error"
    return 1
  }
  status="${resp##*__HTTP_STATUS__:}"
  body="${resp%$'
'__HTTP_STATUS__:*}"

  if [[ ! "$status" =~ ^[0-9]+$ ]]; then
    log "Aliyun response parse error"
    return 1
  fi

  if (( status < 200 || status >= 300 )); then
    log "Aliyun HTTP ${status}: ${body}"
    return 22
  fi

  printf '%s' "$body"
}

ali_get_record() {
  local subdomain body
  subdomain=$(full_record_name)
  body=$(ali_api "Action=DescribeSubDomainRecords
SubDomain=${subdomain}
Type=${RECORD_TYPE}") || return 1
  printf '%s' "$body"
}

ali_upsert_record() {
  local current_ip="$1"
  local body record_id remote_ip full rr_for_api update_body add_body

  body=$(ali_get_record) || die "Aliyun record query failed"
  record_id=$(json_get 'DomainRecords.Record[0].RecordId' <<<"$body" 2>/dev/null || true)
  remote_ip=$(json_get 'DomainRecords.Record[0].Value' <<<"$body" 2>/dev/null || true)
  full=$(full_record_name)
  rr_for_api="$RR"

  if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    if [[ "$remote_ip" == "$current_ip" ]]; then
      log "Aliyun: no change, ${full} already -> ${current_ip}"
      return 0
    fi

    update_body=$(ali_api "Action=UpdateDomainRecord
RecordId=${record_id}
RR=${rr_for_api}
Type=${RECORD_TYPE}
Value=${current_ip}
TTL=${TTL}") || die "Aliyun update request failed"
    if grep -q '"RecordId"' <<<"$update_body"; then
      log "Aliyun: updated ${full} -> ${current_ip}"
    else
      die "Aliyun update failed: $update_body"
    fi
  else
    add_body=$(ali_api "Action=AddDomainRecord
DomainName=${ZONE}
RR=${rr_for_api}
Type=${RECORD_TYPE}
Value=${current_ip}
TTL=${TTL}") || die "Aliyun create request failed"
    if grep -q '"RecordId"' <<<"$add_body"; then
      log "Aliyun: created ${full} -> ${current_ip}"
    else
      die "Aliyun create failed: $add_body"
    fi
  fi
}

run_once() {
  local ip
  ip=$(detect_public_ip) || die "Unable to detect public ${RECORD_TYPE} address"
  log "Detected public ${RECORD_TYPE}: ${ip}"

  case "$PROVIDER" in
    cloudflare) cf_upsert_record "$ip" ;;
    aliyun) ali_upsert_record "$ip" ;;
    *) die "Unsupported provider: $PROVIDER" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider) PROVIDER="$2"; shift 2 ;;
      --zone) ZONE="$2"; shift 2 ;;
      --rr) RR="$2"; shift 2 ;;
      --interval) INTERVAL="$2"; shift 2 ;;
      --type) RECORD_TYPE="$2"; shift 2 ;;
      --ttl) TTL="$2"; shift 2 ;;
      --proxied) PROXIED="$2"; shift 2 ;;
      --once) ONCE="true"; shift ;;
      --ip-sources) IP_SOURCES="$2"; shift 2 ;;
      --cf-token) CF_API_TOKEN="$2"; shift 2 ;;
      --cf-key) CF_API_KEY="$2"; shift 2 ;;
      --cf-email) CF_API_EMAIL="$2"; shift 2 ;;
      --ali-ak) ALI_ACCESS_KEY_ID="$2"; shift 2 ;;
      --ali-sk) ALI_ACCESS_KEY_SECRET="$2"; shift 2 ;;
      --debug) DEBUG="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      --version) printf '%s\n' "$VERSION"; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_args

  log "Starting DDNS worker: provider=${PROVIDER}, zone=${ZONE}, rr=${RR}, type=${RECORD_TYPE}, interval=${INTERVAL}s"

  if [[ "$ONCE" == "true" ]]; then
    run_once
    return 0
  fi

  while true; do
    if ! run_once; then
      log "WARN: run failed, retrying after ${INTERVAL}s"
    fi
    sleep "$INTERVAL"
  done
}

main "$@"
