#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_URL="https://polaris.bnbu.me"
POLARIS_IMAGE="ghcr.io/rainchen537/xboard-node@sha256:ae789704e2f6e90e812e926a37e83a5e3e8cdce4dbdd93b8b72414f0defac6ad"
IMAGE="${XBOARD_IMAGE:-$POLARIS_IMAGE}"
CONTAINER_NAME="${XBOARD_CONTAINER_NAME:-xboard-node}"
DATA_DIR="${XBOARD_DATA_DIR:-/root/xboard-node/config}"
KERNEL="xray"
TOKEN="${POLARIS_TOKEN:-}"
NODES_SPEC=""

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Polaris Xboard-Node Docker 一键部署脚本

用法：
  sudo bash install-polaris-xboard.sh --token TOKEN --nodes '1-33'
  sudo bash install-polaris-xboard.sh --token TOKEN --nodes '1,3,5-8,20'

通过 curl 执行：
  curl -fsSL RAW_SCRIPT_URL | sudo bash -s -- --token 'TOKEN' --nodes '1-33'

更安全的方式（不把 token 放进 shell history；需要交互式终端）：
  curl -fsSL RAW_SCRIPT_URL | sudo bash -s -- --nodes '1-33'

参数：
  --token TOKEN       Polaris 面板 Server Token / API Key
  --nodes SPEC        节点 ID。支持 1-33、1,3,5、1-5,9,20-30
  --kernel TYPE       xray（默认，支持Proxy Protocol）或singbox（回退）
  --data-dir PATH     持久化目录，默认 /root/xboard-node/config
  --name NAME         Docker 容器名，默认 xboard-node
  --image IMAGE       Docker 镜像，默认使用Polaris公开fork的固定多架构digest
  -h, --help          显示帮助

也可以通过环境变量传 token：
  POLARIS_TOKEN='TOKEN' sudo -E bash install-polaris-xboard.sh --nodes '1-33'
USAGE
}

while (($#)); do
  case "$1" in
    --token)
      (($# >= 2)) || die "--token 缺少值"
      TOKEN="$2"
      shift 2
      ;;
    --nodes|--node-ids)
      (($# >= 2)) || die "$1 缺少值"
      NODES_SPEC="$2"
      shift 2
      ;;
    --kernel)
      (($# >= 2)) || die "--kernel 缺少值"
      KERNEL="$2"
      shift 2
      ;;
    --data-dir)
      (($# >= 2)) || die "--data-dir 缺少值"
      DATA_DIR="$2"
      shift 2
      ;;
    --name)
      (($# >= 2)) || die "--name 缺少值"
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --image)
      (($# >= 2)) || die "--image 缺少值"
      IMAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1（使用 --help 查看用法）"
      ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行，例如：sudo bash ..."
[[ "$KERNEL" == "singbox" || "$KERNEL" == "xray" ]] || die "--kernel 只能是 singbox 或 xray"
[[ -n "$NODES_SPEC" ]] || die "必须指定 --nodes，例如 --nodes '1-33'"
PROXY_PROTOCOL_READY=0
if [[ "$KERNEL" == "xray" && "$IMAGE" == "$POLARIS_IMAGE" ]]; then
  PROXY_PROTOCOL_READY=1
else
  warn "当前内核或镜像不是Polaris固定Xray组合，不声明Proxy Protocol就绪。"
fi

# curl | bash 时 stdin 已被脚本占用，因此从 /dev/tty 安全读取 token。
if [[ -z "$TOKEN" ]]; then
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '请输入 Polaris Server Token/API Key: ' >/dev/tty
    IFS= read -r -s TOKEN </dev/tty || true
    printf '\n' >/dev/tty
  fi
fi
[[ -n "$TOKEN" ]] || die "没有提供 token。请使用 --token TOKEN，或在交互式终端中让脚本提示输入。"
[[ "$TOKEN" != *$'\n'* && "$TOKEN" != *$'\r'* ]] || die "token 不能包含换行符"

# 解析节点表达式：1-33 / 1,3,5 / 1-5,9,20-30
expand_nodes() {
  local spec="$1" part start end i
  local -a parts
  declare -g -a NODE_IDS=()
  declare -A seen=()

  # 允许逗号和连字符两侧有空格。
  spec="$(printf '%s' "$spec" | sed -E 's/[[:space:]]*-[[:space:]]*/-/g; s/[[:space:]]*,[[:space:]]*/,/g')"
  IFS=',' read -r -a parts <<< "$spec"

  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || die "节点表达式包含空项：$spec"
    if [[ "$part" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      (( start <= end )) || die "节点范围错误：$part"
      # 防止误输入一个极大的范围导致生成超大配置。
      (( end - start <= 10000 )) || die "单个节点范围过大：$part"
      for ((i=start; i<=end; i++)); do
        if [[ -z "${seen[$i]+x}" ]]; then
          NODE_IDS+=("$i")
          seen[$i]=1
        fi
      done
    elif [[ "$part" =~ ^[1-9][0-9]*$ ]]; then
      i="$part"
      if [[ -z "${seen[$i]+x}" ]]; then
        NODE_IDS+=("$i")
        seen[$i]=1
      fi
    else
      die "无法识别节点 ID：$part"
    fi
  done

  ((${#NODE_IDS[@]} > 0)) || die "没有解析到有效节点"
}

expand_nodes "$NODES_SPEC"

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  log "未检测到 Docker，开始安装..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq docker.io ca-certificates >/dev/null
  else
    command -v curl >/dev/null 2>&1 || die "系统没有 Docker，也没有 curl，无法自动安装 Docker"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi

  command -v docker >/dev/null 2>&1 || die "Docker 安装失败"
}

install_docker_if_needed
docker info >/dev/null 2>&1 || die "Docker daemon 当前不可用"

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet xboard-node.service 2>/dev/null; then
  warn "检测到宿主机 xboard-node.service 正在运行。脚本不会修改它；Docker 使用 host 网络，节点业务端口不能与宿主机服务重复。"
fi

BASE_DIR="$(dirname "$DATA_DIR")"
BACKUP_DIR="$BASE_DIR/backups"
CONFIG_FILE="$DATA_DIR/config.yml"
ENV_FILE="$DATA_DIR/credentials.env"
mkdir -p "$DATA_DIR" "$BACKUP_DIR"
chmod 700 "$DATA_DIR" || true

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_BACKUP_DIR="$BACKUP_DIR/deploy-$STAMP"
umask 077
install -d -m 0700 "$RUN_BACKUP_DIR"
OLD_CONFIG_EXISTED=0
OLD_ENV_EXISTED=0
HAD_OLD_CONTAINER=0
OLD_IMAGE_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "$RUN_BACKUP_DIR/config.yml"
  OLD_CONFIG_EXISTED=1
  log "已备份旧配置：$RUN_BACKUP_DIR/config.yml"
fi
if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$RUN_BACKUP_DIR/credentials.env"
  OLD_ENV_EXISTED=1
fi
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  HAD_OLD_CONTAINER=1
  OLD_IMAGE_ID="$(docker inspect "$CONTAINER_NAME" --format '{{.Image}}')"
  docker inspect "$CONTAINER_NAME" > "$RUN_BACKUP_DIR/container-inspect.json"
  docker logs --tail 200 "$CONTAINER_NAME" > "$RUN_BACKUP_DIR/container-before.log" 2>&1 || true
fi
chmod -R go-rwx "$RUN_BACKUP_DIR"

TMP_CONFIG="$(mktemp "$DATA_DIR/.config.yml.XXXXXX")"
TMP_ENV="$(mktemp "$DATA_DIR/.credentials.env.XXXXXX")"
cleanup_tmp() { rm -f "$TMP_CONFIG" "$TMP_ENV"; }
trap cleanup_tmp EXIT

cat > "$TMP_CONFIG" <<EOF_CONFIG
# Managed by Polaris Xboard-Node installer.
# Re-run the installer to update token or node IDs.

panel:
  url: "$PANEL_URL"
  token_env: "POLARIS_PANEL_TOKEN"

kernel:
  type: "$KERNEL"
  log_level: "warn"

log:
  level: "info"
  output: "stdout"

nodes:
EOF_CONFIG

for id in "${NODE_IDS[@]}"; do
  printf '  - node_id: %s\n' "$id" >> "$TMP_CONFIG"
done

printf 'POLARIS_PANEL_TOKEN=%s\n' "$TOKEN" > "$TMP_ENV"
chmod 600 "$TMP_CONFIG" "$TMP_ENV"

log "拉取固定镜像：$IMAGE"
docker pull "$IMAGE"
TARGET_IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
[[ -n "$TARGET_IMAGE_ID" ]] || die "拉取后无法读取目标镜像ID"

DEPLOYMENT_STARTED=0
rollback_deployment() {
  local status="${1:-1}"
  trap - ERR INT TERM
  set +e
  if (( DEPLOYMENT_STARTED )); then
    warn "部署失败，开始恢复部署前状态。"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    if (( OLD_CONFIG_EXISTED )); then
      cp -a "$RUN_BACKUP_DIR/config.yml" "$CONFIG_FILE.polaris-rollback"
      mv -f "$CONFIG_FILE.polaris-rollback" "$CONFIG_FILE"
    else
      rm -f "$CONFIG_FILE"
    fi
    if (( OLD_ENV_EXISTED )); then
      cp -a "$RUN_BACKUP_DIR/credentials.env" "$ENV_FILE.polaris-rollback"
      mv -f "$ENV_FILE.polaris-rollback" "$ENV_FILE"
    else
      rm -f "$ENV_FILE"
    fi
    if (( HAD_OLD_CONTAINER )) && [[ -n "$OLD_IMAGE_ID" ]]; then
      chmod 600 "$CONFIG_FILE" "$ENV_FILE"
      docker run -d \
        --name "$CONTAINER_NAME" \
        --restart=unless-stopped \
        --network=host \
        --env-file "$ENV_FILE" \
        -v "$DATA_DIR:/etc/xboard-node" \
        "$OLD_IMAGE_ID" >/dev/null
      sleep 5
      docker inspect "$CONTAINER_NAME" \
        --format 'rollback_status={{.State.Status}} restart_count={{.RestartCount}}' >&2
    fi
    warn "恢复流程已执行，备份：$RUN_BACKUP_DIR"
  fi
  exit "$status"
}
trap 'rollback_deployment $?' ERR
trap 'rollback_deployment 130' INT TERM

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  log "停止并移除旧容器：$CONTAINER_NAME"
  DEPLOYMENT_STARTED=1
  docker stop "$CONTAINER_NAME" >/dev/null
  docker rm "$CONTAINER_NAME" >/dev/null
else
  DEPLOYMENT_STARTED=1
fi

# 原子替换配置，避免运行中的 watcher 读到写了一半的 YAML。
mv -f "$TMP_CONFIG" "$CONFIG_FILE"
mv -f "$TMP_ENV" "$ENV_FILE"
TMP_CONFIG=""
TMP_ENV=""
chmod 600 "$CONFIG_FILE" "$ENV_FILE"

log "启动 Xboard-Node Docker 容器..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart=unless-stopped \
  --network=host \
  --env-file "$ENV_FILE" \
  -v "$DATA_DIR:/etc/xboard-node" \
  "$IMAGE" >/dev/null

HEALTHY=0
for _ in $(seq 1 20); do
  STATUS="$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || true)"
  RESTARTS="$(docker inspect "$CONTAINER_NAME" --format '{{.RestartCount}}' 2>/dev/null || echo 999)"
  if [[ "$STATUS" == "running" && "$RESTARTS" == "0" ]]; then
    if [[ "$KERNEL" != "xray" ]] || docker logs "$CONTAINER_NAME" 2>&1 | grep -Fq 'xray started'; then
      HEALTHY=1
      break
    fi
  fi
  sleep 2
done
if (( HEALTHY != 1 )); then
  warn "容器未在时限内进入目标内核健康状态。最近日志："
  docker logs --tail 120 "$CONTAINER_NAME" 2>&1 || true
  false
fi
if docker logs "$CONTAINER_NAME" 2>&1 | \
  grep -Eiq 'invalid token|token invalid|handshake[^[:cntrl:]]*(401|403|422)|panic|fatal'; then
  warn "日志出现Token、握手或致命错误。"
  false
fi
RUNNING_IMAGE_ID="$(docker inspect "$CONTAINER_NAME" --format '{{.Image}}')"
if [[ "$RUNNING_IMAGE_ID" != "$TARGET_IMAGE_ID" ]]; then
  warn "运行容器镜像ID与拉取目标不一致。"
  false
fi
trap - ERR INT TERM
DEPLOYMENT_STARTED=0

log "部署完成"
printf '\n'
printf 'Panel:      %s\n' "$PANEL_URL"
printf 'Container:  %s\n' "$CONTAINER_NAME"
printf 'Image:      %s\n' "$IMAGE"
printf 'Config:     %s\n' "$CONFIG_FILE"
printf 'Credential: %s (mode 600)\n' "$ENV_FILE"
printf 'Kernel:     %s\n' "$KERNEL"
printf 'Nodes (%d): %s\n' "${#NODE_IDS[@]}" "${NODE_IDS[*]}"
printf 'Restarts:   %s\n' "$RESTARTS"
printf 'Backup:     %s\n' "$RUN_BACKUP_DIR"
if (( PROXY_PROTOCOL_READY )); then
  printf 'Proxy PP:   ready（XBoard接收与Nyanpass发送仍默认关闭）\n'
else
  printf 'Proxy PP:   unavailable（内核或镜像不符合Polaris固定组合）\n'
fi
printf '\n'

if [[ "$RESTARTS" =~ ^[0-9]+$ ]] && (( RESTARTS > 0 )); then
  warn "容器启动后已经发生 $RESTARTS 次重启，请重点检查下面日志。"
fi

log "最近日志："
docker logs --tail 80 "$CONTAINER_NAME" 2>&1 || true

printf '\n'
log "当前 xboard-node 监听端口："
ss -lntup 2>/dev/null | grep -E 'xboard-node' || true

printf '\n'
printf '常用命令：\n'
printf '  docker logs -f --tail 100 %s\n' "$CONTAINER_NAME"
printf '  docker restart %s\n' "$CONTAINER_NAME"
printf '  docker ps --filter name=%s\n' "$CONTAINER_NAME"
