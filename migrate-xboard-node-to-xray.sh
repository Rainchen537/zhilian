#!/usr/bin/env bash

set -Eeuo pipefail

container_name="${XBOARD_CONTAINER_NAME:-xboard-node}"
data_dir="${XBOARD_DATA_DIR:-/root/xboard-node/config}"
target_image="${XBOARD_TARGET_IMAGE:-ghcr.io/rainchen537/xboard-node@sha256:ae789704e2f6e90e812e926a37e83a5e3e8cdce4dbdd93b8b72414f0defac6ad}"
dry_run=0

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  printf '%s\n' \
    'Polaris Xboard-Node 旧机器 Xray 迁移脚本' \
    '' \
    '用法：' \
    '  sudo bash migrate_xboard_node_to_xray.sh' \
    '  bash migrate_xboard_node_to_xray.sh --dry-run' \
    '' \
    '参数：' \
    '  --dry-run        只验证配置并展示迁移范围' \
    '  --container NAME 旧脚本创建的容器名，默认 xboard-node' \
    '  --data-dir PATH  旧脚本配置目录，默认 /root/xboard-node/config' \
    '  --image IMAGE    固定目标镜像，默认使用Polaris公开fork的已验证多架构digest' \
    '  -h, --help       显示帮助'
}

while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --container)
      (($# >= 2)) || die '--container 缺少值'
      container_name="$2"
      shift 2
      ;;
    --data-dir)
      (($# >= 2)) || die '--data-dir 缺少值'
      data_dir="$2"
      shift 2
      ;;
    --image)
      (($# >= 2)) || die '--image 缺少值'
      target_image="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ -n "$container_name" && "$container_name" != */* ]] || die '容器名无效'
[[ "$data_dir" == /* && "$data_dir" != '/' ]] || die '配置目录必须是非根目录绝对路径'
[[ -n "$target_image" ]] || die '目标镜像不能为空'

config_file="$data_dir/config.yml"
env_file="$data_dir/credentials.env"
[[ -f "$config_file" ]] || die "缺少配置：$config_file"
[[ -f "$env_file" ]] || die "缺少凭据文件：$env_file"
[[ -s "$env_file" ]] || die '凭据文件为空'

current_kernel="$(awk '
  /^kernel:[[:space:]]*$/ { in_kernel=1; next }
  in_kernel && /^[^[:space:]]/ { in_kernel=0 }
  in_kernel && /^[[:space:]]+type:[[:space:]]*/ {
    value=$0
    sub(/^[[:space:]]+type:[[:space:]]*/, "", value)
    gsub(/["'\''[:space:]]/, "", value)
    print value
    exit
  }
' "$config_file")"
[[ "$current_kernel" == 'singbox' || "$current_kernel" == 'xray' ]] || \
  die '无法唯一识别 kernel.type，仅支持旧安装脚本生成的 singbox/xray 配置'

mapfile_supported=1
if ! type mapfile >/dev/null 2>&1; then
  mapfile_supported=0
fi
if ((mapfile_supported)); then
  mapfile -t node_ids < <(
    sed -nE 's/^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*([1-9][0-9]*)[[:space:]]*$/\1/p' \
      "$config_file"
  )
else
  node_ids=()
  while IFS= read -r node_id; do
    node_ids+=("$node_id")
  done < <(
    sed -nE 's/^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*([1-9][0-9]*)[[:space:]]*$/\1/p' \
      "$config_file"
  )
fi
((${#node_ids[@]} > 0)) || die '没有读取到 nodes.node_id'
unique_node_count="$(printf '%s\n' "${node_ids[@]}" | sort -n -u | wc -l | tr -d ' ')"
[[ "$unique_node_count" == "${#node_ids[@]}" ]] || die '节点 ID 存在重复'

candidate_file="$(mktemp "${TMPDIR:-/tmp}/polaris-xray-config.XXXXXX")"
normalized_current="$(mktemp "${TMPDIR:-/tmp}/polaris-xray-current.XXXXXX")"
normalized_candidate="$(mktemp "${TMPDIR:-/tmp}/polaris-xray-candidate.XXXXXX")"
cleanup_files() {
  rm -f -- "$candidate_file" "$normalized_current" "$normalized_candidate"
}
trap cleanup_files EXIT

awk '
  BEGIN { in_kernel=0; changed=0 }
  /^kernel:[[:space:]]*$/ { in_kernel=1; print; next }
  in_kernel && /^[^[:space:]]/ { in_kernel=0 }
  in_kernel && /^[[:space:]]+type:[[:space:]]*/ {
    indent=$0
    sub(/type:.*/, "", indent)
    print indent "type: \"xray\""
    changed++
    next
  }
  { print }
  END { if (changed != 1) exit 42 }
' "$config_file" > "$candidate_file" || die '生成候选配置失败'

normalize_kernel() {
  awk '
    BEGIN { in_kernel=0 }
    /^kernel:[[:space:]]*$/ { in_kernel=1; print; next }
    in_kernel && /^[^[:space:]]/ { in_kernel=0 }
    in_kernel && /^[[:space:]]+type:[[:space:]]*/ {
      indent=$0
      sub(/type:.*/, "", indent)
      print indent "type: \"__KERNEL__\""
      next
    }
    { print }
  ' "$1"
}
normalize_kernel "$config_file" > "$normalized_current"
normalize_kernel "$candidate_file" > "$normalized_candidate"
cmp -s "$normalized_current" "$normalized_candidate" || \
  die '候选配置除 kernel.type 外还有其他变化'

log "容器：$container_name"
log "配置：$config_file"
log "内核：$current_kernel -> xray"
log "节点（${#node_ids[@]}）：${node_ids[*]}"
log "目标镜像：$target_image"

if ((dry_run)); then
  log 'dry-run通过；未读取凭据内容、未拉取镜像、未修改配置或容器'
  exit 0
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || die '正式迁移必须使用 root 或 sudo'
command -v docker >/dev/null 2>&1 || die '未安装 Docker'
docker info >/dev/null 2>&1 || die 'Docker daemon 不可用'
docker inspect "$container_name" >/dev/null 2>&1 || die '目标容器不存在'

container_status="$(docker inspect "$container_name" --format '{{.State.Status}}')"
[[ "$container_status" == 'running' ]] || die "旧容器状态不是 running：$container_status"
network_mode="$(docker inspect "$container_name" --format '{{.HostConfig.NetworkMode}}')"
[[ "$network_mode" == 'host' ]] || die "旧容器不是 host 网络：$network_mode"
restart_policy="$(docker inspect "$container_name" --format '{{.HostConfig.RestartPolicy.Name}}')"
[[ "$restart_policy" == 'unless-stopped' ]] || \
  die "旧容器重启策略不符合旧脚本合同：$restart_policy"
mounted_config="$(docker inspect "$container_name" --format \
  '{{range .Mounts}}{{if eq .Destination "/etc/xboard-node"}}{{.Source}}{{end}}{{end}}')"
resolved_data_dir="$(cd "$data_dir" && pwd -P)"
[[ "$mounted_config" == "$resolved_data_dir" ]] || \
  die "容器配置挂载不匹配：$mounted_config"

old_image_ref="$(docker inspect "$container_name" --format '{{.Config.Image}}')"
old_image_id="$(docker inspect "$container_name" --format '{{.Image}}')"
[[ -n "$old_image_ref" && -n "$old_image_id" ]] || die '无法读取旧镜像信息'

base_dir="$(dirname "$data_dir")"
backup_root="$base_dir/backups"
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$backup_root/xray-migration-$stamp"
umask 077
install -d -m 0700 "$backup_dir"
cp -a "$config_file" "$backup_dir/config.yml"
cp -a "$env_file" "$backup_dir/credentials.env"
docker inspect "$container_name" > "$backup_dir/container-inspect.json"
docker logs --tail 200 "$container_name" > "$backup_dir/container-before.log" 2>&1 || true
printf '%s\n' "$old_image_ref" > "$backup_dir/old-image-reference.txt"
printf '%s\n' "$old_image_id" > "$backup_dir/old-image-id.txt"
cp -a "$candidate_file" "$backup_dir/config.xray.candidate.yml"
chmod -R go-rwx "$backup_dir"
log "备份完成：$backup_dir"

docker pull "$target_image"
target_image_id="$(docker image inspect "$target_image" --format '{{.Id}}')"
[[ -n "$target_image_id" ]] || die '目标镜像拉取后无法读取镜像ID'

migration_started=0
rollback() {
  status=$?
  trap - ERR INT TERM
  if ((migration_started)); then
    warn '迁移失败，开始自动恢复旧内核容器'
    set +e
    docker rm -f "$container_name" >/dev/null 2>&1
    cp -a "$backup_dir/config.yml" "$config_file.rollback"
    mv -f "$config_file.rollback" "$config_file"
    chmod 600 "$config_file" "$env_file"
    docker run -d \
      --name "$container_name" \
      --restart="$restart_policy" \
      --network=host \
      --env-file "$env_file" \
      -v "$data_dir:/etc/xboard-node" \
      "$old_image_id" >/dev/null
    sleep 5
    docker inspect "$container_name" --format 'rollback_status={{.State.Status}} restart_count={{.RestartCount}}' >&2
    warn "自动恢复已执行，备份：$backup_dir"
  fi
  exit "$status"
}
trap rollback ERR INT TERM

docker stop "$container_name" >/dev/null
docker rm "$container_name" >/dev/null
migration_started=1
cp -a "$candidate_file" "$config_file.polaris-new"
chmod 600 "$config_file.polaris-new"
mv -f "$config_file.polaris-new" "$config_file"

docker run -d \
  --name "$container_name" \
  --restart="$restart_policy" \
  --network=host \
  --env-file "$env_file" \
  -v "$data_dir:/etc/xboard-node" \
  "$target_image" >/dev/null

healthy=0
for _ in $(seq 1 20); do
  new_status="$(docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || true)"
  new_restarts="$(docker inspect "$container_name" --format '{{.RestartCount}}' 2>/dev/null || echo 999)"
  if [[ "$new_status" == 'running' && "$new_restarts" == '0' ]] && \
    docker logs "$container_name" 2>&1 | grep -Fq 'xray started'; then
    healthy=1
    break
  fi
  sleep 2
done
((healthy == 1)) || die 'Xray容器没有在时限内进入已启动状态'

if docker logs "$container_name" 2>&1 | \
  grep -Eiq 'invalid token|token invalid|handshake[^[:cntrl:]]*(401|403|422)|panic|fatal'; then
  die 'Xray容器日志出现Token、握手或致命错误'
fi
final_status="$(docker inspect "$container_name" --format '{{.State.Status}}')"
final_restarts="$(docker inspect "$container_name" --format '{{.RestartCount}}')"
[[ "$final_status" == 'running' && "$final_restarts" == '0' ]] || \
  die "Xray容器状态异常：$final_status/$final_restarts"
grep -Eq '^[[:space:]]+type:[[:space:]]*["'\'']?xray["'\'']?[[:space:]]*$' "$config_file" || \
  die '最终配置没有保持 kernel.type=xray'
normalize_kernel "$config_file" > "$normalized_candidate"
cmp -s "$normalized_current" "$normalized_candidate" || \
  die '最终配置除 kernel.type 外发生变化'

docker logs --tail 200 "$container_name" > "$backup_dir/container-after.log" 2>&1 || true
printf '%s\n' "$target_image" > "$backup_dir/target-image-reference.txt"
printf '%s\n' "$target_image_id" > "$backup_dir/target-image-id.txt"
trap - ERR INT TERM
migration_started=0

log 'Xray内核迁移完成'
printf 'Container: %s\n' "$container_name"
printf 'Nodes:     %s\n' "${node_ids[*]}"
printf 'Image:     %s\n' "$target_image"
printf 'Backup:    %s\n' "$backup_dir"
printf '接收 Proxy Protocol 仍由 Xboard 节点开关控制；当前脚本不会开启它。\n'
