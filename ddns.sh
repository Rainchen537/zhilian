#!/usr/bin/env bash
set -Eeuo pipefail

PROVIDER=""
ZONE=""
RR=""
INTERVAL="300"
RECORD_TYPE="A"
TTL=""
PROXIED="false"
IP_SOURCES=""
DEBUG="false"
SERVICE_NAME=""

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_API_KEY="${CF_API_KEY:-}"
CF_API_EMAIL="${CF_API_EMAIL:-}"
ALI_ACCESS_KEY_ID="${ALI_ACCESS_KEY_ID:-}"
ALI_ACCESS_KEY_SECRET="${ALI_ACCESS_KEY_SECRET:-}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  install-ddns-service.sh --provider cloudflare|aliyun --zone example.com --rr home --interval 300 [options]

Required:
  --provider       cloudflare | aliyun
  --zone           Root zone, e.g. example.com
  --rr             Host record, e.g. @ | home | www
  --interval       Check interval in seconds

Optional:
  --service-name   Custom systemd service name
  --type           A | AAAA (default: A)
  --ttl            TTL (default: 120 for Cloudflare, 600 for Aliyun)
  --proxied        Cloudflare only: true | false (default: false)
  --ip-sources     Custom IP source URLs, comma-separated
  --debug          Enable verbose worker logs
  -h, --help       Show help

Credentials via environment:
  Cloudflare:
    CF_API_TOKEN=...
    or CF_API_KEY=... CF_API_EMAIL=...

  Aliyun:
    ALI_ACCESS_KEY_ID=...
    ALI_ACCESS_KEY_SECRET=...
USAGE
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_name() {
  local s="$1"
  s="${s//@/root}"
  s="${s//[^a-zA-Z0-9_.-]/-}"
  s="${s//./-}"
  s="${s//_/-}"
  while [[ "$s" == *"--"* ]]; do
    s="${s//--/-}"
  done
  s="${s#-}"
  s="${s%-}"
  printf '%s' "$s"
}

shell_kv() {
  local key="$1"
  local value="$2"
  printf '%s=%q\n' "$key" "$value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider) PROVIDER="$2"; shift 2 ;;
      --zone) ZONE="$2"; shift 2 ;;
      --rr) RR="$2"; shift 2 ;;
      --interval) INTERVAL="$2"; shift 2 ;;
      --service-name) SERVICE_NAME="$2"; shift 2 ;;
      --type) RECORD_TYPE="$2"; shift 2 ;;
      --ttl) TTL="$2"; shift 2 ;;
      --proxied) PROXIED="$2"; shift 2 ;;
      --ip-sources) IP_SOURCES="$2"; shift 2 ;;
      --debug) DEBUG="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

require_args() {
  [[ $EUID -eq 0 ]] || die "Please run as root"
  has_cmd systemctl || die "systemctl is required"
  has_cmd journalctl || die "journalctl is required"
  has_cmd bash || die "bash is required"
  has_cmd curl || die "curl is required"
  has_cmd openssl || die "openssl is required"
  if ! has_cmd jq && ! has_cmd python3; then
    die "Need jq or python3 on the target machine"
  fi

  [[ -n "$PROVIDER" ]] || die "--provider is required"
  [[ -n "$ZONE" ]] || die "--zone is required"
  [[ -n "$RR" ]] || die "--rr is required"
  [[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "--interval must be an integer"
  [[ "$RECORD_TYPE" == "A" || "$RECORD_TYPE" == "AAAA" ]] || die "--type must be A or AAAA"

  case "$PROVIDER" in
    cloudflare)
      if [[ -z "$TTL" ]]; then TTL="120"; fi
      [[ "$TTL" =~ ^[0-9]+$ ]] || die "--ttl must be an integer"
      if [[ -z "$CF_API_TOKEN" && ( -z "$CF_API_KEY" || -z "$CF_API_EMAIL" ) ]]; then
        die "Cloudflare requires CF_API_TOKEN or (CF_API_KEY + CF_API_EMAIL)"
      fi
      ;;
    aliyun)
      if [[ -z "$TTL" ]]; then TTL="600"; fi
      [[ "$TTL" =~ ^[0-9]+$ ]] || die "--ttl must be an integer"
      [[ -n "$ALI_ACCESS_KEY_ID" ]] || die "Aliyun requires ALI_ACCESS_KEY_ID"
      [[ -n "$ALI_ACCESS_KEY_SECRET" ]] || die "Aliyun requires ALI_ACCESS_KEY_SECRET"
      ;;
    *) die "Unsupported provider: $PROVIDER" ;;
  esac

  if [[ -z "$SERVICE_NAME" ]]; then
    SERVICE_NAME="ddns-$(sanitize_name "$PROVIDER")-$(sanitize_name "$ZONE")-$(sanitize_name "$RR")"
  else
    SERVICE_NAME="$(sanitize_name "$SERVICE_NAME")"
  fi
  [[ -n "$SERVICE_NAME" ]] || die "Service name resolved to empty string"
}

write_env() {
  local env_file="$1"
  umask 077
  mkdir -p /etc/ddns
  : > "$env_file"
  shell_kv PROVIDER "$PROVIDER" >> "$env_file"
  shell_kv ZONE "$ZONE" >> "$env_file"
  shell_kv RR "$RR" >> "$env_file"
  shell_kv INTERVAL "$INTERVAL" >> "$env_file"
  shell_kv RECORD_TYPE "$RECORD_TYPE" >> "$env_file"
  shell_kv TTL "$TTL" >> "$env_file"
  shell_kv PROXIED "$PROXIED" >> "$env_file"
  shell_kv IP_SOURCES "$IP_SOURCES" >> "$env_file"
  shell_kv DEBUG "$DEBUG" >> "$env_file"

  [[ -n "$CF_API_TOKEN" ]] && shell_kv CF_API_TOKEN "$CF_API_TOKEN" >> "$env_file"
  [[ -n "$CF_API_KEY" ]] && shell_kv CF_API_KEY "$CF_API_KEY" >> "$env_file"
  [[ -n "$CF_API_EMAIL" ]] && shell_kv CF_API_EMAIL "$CF_API_EMAIL" >> "$env_file"
  [[ -n "$ALI_ACCESS_KEY_ID" ]] && shell_kv ALI_ACCESS_KEY_ID "$ALI_ACCESS_KEY_ID" >> "$env_file"
  [[ -n "$ALI_ACCESS_KEY_SECRET" ]] && shell_kv ALI_ACCESS_KEY_SECRET "$ALI_ACCESS_KEY_SECRET" >> "$env_file"
  chmod 600 "$env_file"
}

write_runner() {
  local runner_file="$1"
  mkdir -p /usr/local/lib/ddns
  cat > "$runner_file" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${1:-}"
[[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] || {
  printf '[%s] ERROR: env file not found: %s\n' "$(date '+%F %T')" "$ENV_FILE" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$ENV_FILE"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    log "DEBUG: $*"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

trap 'log "Received stop signal, exiting"; exit 0' INT TERM

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
    python3 -c 'import sys,json; data=json.load(sys.stdin); expr=sys.argv[1]
def get(obj, expr):
    cur=obj
    for part in expr.split("."):
        if not part:
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
v=get(data, expr)
if isinstance(v, bool):
    print(str(v).lower())
elif v is None:
    print("")
elif isinstance(v, (dict,list)):
    print(json.dumps(v, ensure_ascii=False))
else:
    print(v)
' "$expr"
  else
    return 1
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
    sys.exit(0 if data.get("success") is True else 1)
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
      (( n >= 0 && n <= 255 )) || return 1
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

try_ip_cmd() {
  local label="$1"
  shift
  local ip=""
  debug "Trying IP source: $label"
  if ip=$("$@" 2>/dev/null | tr -d '[:space:]'); then
    if validate_ip "$ip" "$RECORD_TYPE"; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  return 1
}

detect_public_ip() {
  local src
  if [[ -n "${IP_SOURCES:-}" ]]; then
    while IFS= read -r src; do
      [[ -n "$src" ]] || continue
      if [[ "$RECORD_TYPE" == "A" ]]; then
        try_ip_cmd "curl -4 $src" curl -4 -fsS --max-time 10 "$src" && return 0
      else
        try_ip_cmd "curl -6 $src" curl -6 -fsS --max-time 10 "$src" && return 0
      fi
    done < <(tr ',' '\n' <<<"$IP_SOURCES")
    return 1
  fi

  if [[ "$RECORD_TYPE" == "A" ]]; then
    try_ip_cmd 'curl -4 ifconfig.me' curl -4 -fsS --max-time 10 ifconfig.me && return 0
    try_ip_cmd 'curl -4 https://api.ipify.org' curl -4 -fsS --max-time 10 https://api.ipify.org && return 0
    try_ip_cmd 'curl -4 https://ipv4.icanhazip.com' curl -4 -fsS --max-time 10 https://ipv4.icanhazip.com && return 0
  else
    try_ip_cmd 'curl -6 ifconfig.me' curl -6 -fsS --max-time 10 ifconfig.me && return 0
    try_ip_cmd 'curl -6 https://api6.ipify.org' curl -6 -fsS --max-time 10 https://api6.ipify.org && return 0
    try_ip_cmd 'curl -6 https://ipv6.icanhazip.com' curl -6 -fsS --max-time 10 https://ipv6.icanhazip.com && return 0
  fi
  return 1
}

full_record_name() {
  if [[ "$RR" == "@" ]]; then
    printf '%s' "$ZONE"
  else
    printf '%s.%s' "$RR" "$ZONE"
  fi
}

cf_auth_args() {
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
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
  local tmp status body
  local -a args
  mapfile -t args < <(cf_auth_args)
  tmp=$(mktemp)
  if [[ -n "$data" ]]; then
    status=$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$url" "${args[@]}" --data "$data") || {
      body=$(cat "$tmp" 2>/dev/null || true)
      rm -f "$tmp"
      log "Cloudflare request failed: $body"
      return 1
    }
  else
    status=$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" "$url" "${args[@]}") || {
      body=$(cat "$tmp" 2>/dev/null || true)
      rm -f "$tmp"
      log "Cloudflare request failed: $body"
      return 1
    }
  fi
  body=$(cat "$tmp")
  rm -f "$tmp"
  if [[ "$status" != "200" ]]; then
    log "Cloudflare HTTP $status: $body"
    return 1
  fi
  printf '%s' "$body"
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
  local zone_id record_body record_id remote_ip payload name body

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
    payload=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' "$RECORD_TYPE" "$name" "$current_ip" "$TTL" "$PROXIED")
    body=$(cf_api PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" "$payload") || die "Cloudflare update request failed"
    json_bool_success "$body" || die "Cloudflare update failed: $body"
    log "Cloudflare: updated ${name} -> ${current_ip}"
  else
    payload=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' "$RECORD_TYPE" "$name" "$current_ip" "$TTL" "$PROXIED")
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
  {
    ali_common_params
    printf '%s\n' "$extra"
  } | while IFS= read -r key value; do
    [[ -n "$key" ]] || continue
    printf '%s=%s\n' "$(ali_percent_encode "$key")" "$(ali_percent_encode "$value")"
  done | LC_ALL=C sort | paste -sd'&' -
}

ali_api() {
  local extra="$1"
  local canonical signature final_query url tmp status body
  canonical=$(ali_build_query "$extra")
  signature=$(ali_sign_query "$canonical")
  final_query="${canonical}&Signature=$(ali_percent_encode "$signature")"
  url="https://alidns.aliyuncs.com/?${final_query}"
  debug "Aliyun URL: $url"
  tmp=$(mktemp)
  status=$(curl -sS -o "$tmp" -w '%{http_code}' "$url") || {
    body=$(cat "$tmp" 2>/dev/null || true)
    rm -f "$tmp"
    log "Aliyun request failed: $body"
    return 1
  }
  body=$(cat "$tmp")
  rm -f "$tmp"
  if [[ "$status" != "200" ]]; then
    log "Aliyun HTTP $status: $body"
    return 1
  fi
  printf '%s' "$body"
}

ali_get_record() {
  local subdomain
  subdomain=$(full_record_name)
  ali_api "Action=DescribeSubDomainRecords
SubDomain=${subdomain}
Type=${RECORD_TYPE}"
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

main() {
  [[ "${PROVIDER:-}" == "aliyun" && "${TTL:-600}" =~ ^[0-9]+$ && "${TTL:-600}" -lt 600 ]] && log "WARN: Aliyun often requires TTL >= 600; current TTL=${TTL} may fail"
  log "Starting DDNS worker: provider=${PROVIDER}, zone=${ZONE}, rr=${RR}, type=${RECORD_TYPE}, interval=${INTERVAL}s"
  while true; do
    if ! run_once; then
      log "WARN: run failed, retrying after ${INTERVAL}s"
    fi
    sleep "$INTERVAL"
  done
}

main "$@"
RUNNER
  chmod 700 "$runner_file"
}

write_unit() {
  local unit_file="$1"
  local runner_file="$2"
  local env_file="$3"
  cat > "$unit_file" <<EOF
[Unit]
Description=DDNS Service (${SERVICE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${runner_file} ${env_file}
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$unit_file"
}

recreate_service() {
  local unit_file="$1"
  local runner_file="$2"
  local env_file="$3"

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service" || [[ -f "$unit_file" ]]; then
    log "Existing service found, recreating: ${SERVICE_NAME}.service"
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
  fi

  rm -f "$unit_file" "$runner_file" "$env_file"

  write_env "$env_file"
  write_runner "$runner_file"
  write_unit "$unit_file" "$runner_file" "$env_file"

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
}

main() {
  parse_args "$@"
  require_args

  local env_file="/etc/ddns/${SERVICE_NAME}.env"
  local runner_file="/usr/local/lib/ddns/${SERVICE_NAME}.runner.sh"
  local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"

  log "Installing service: ${SERVICE_NAME}.service"
  recreate_service "$unit_file" "$runner_file" "$env_file"
  log "Service installed and started: ${SERVICE_NAME}.service"
  log "Streaming logs below. Press Ctrl+C to stop viewing; the service will keep running."
  exec journalctl -u "${SERVICE_NAME}.service" -n 50 -f
}

main "$@"
