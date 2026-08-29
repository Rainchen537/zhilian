#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/polaris-install-test.XXXXXX")"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fake_bin="$test_root/bin"
fake_state="$test_root/docker-running"
data_dir="$test_root/xboard/config"
mkdir -p "$fake_bin" "$data_dir"

cat > "$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info)
    exit 0
    ;;
  pull)
    printf 'pulled %s\n' "${2:-}"
    ;;
  image)
    [[ "${2:-}" == 'inspect' ]]
    printf 'sha256:polaris-test-image\n'
    ;;
  inspect)
    [[ -f "$FAKE_DOCKER_STATE" ]] || exit 1
    format=''
    while (($#)); do
      if [[ "$1" == '--format' ]]; then
        format="${2:-}"
        break
      fi
      shift
    done
    case "$format" in
      *State.Status*) printf 'running\n' ;;
      *RestartCount*) printf '0\n' ;;
      *'{{.Image}}'*) printf 'sha256:polaris-test-image\n' ;;
      *) printf '{}\n' ;;
    esac
    ;;
  run)
    : > "$FAKE_DOCKER_STATE"
    printf 'fake-container-id\n'
    ;;
  logs)
    printf 'xray started protocol=shadowsocks\n'
    ;;
  stop|rm)
    rm -f "$FAKE_DOCKER_STATE"
    ;;
  *)
    printf 'unsupported fake docker command: %s\n' "$*" >&2
    exit 90
    ;;
esac
FAKE_DOCKER
chmod +x "$fake_bin/docker"

output="$(
  PATH="$fake_bin:/usr/bin:/bin" \
  FAKE_DOCKER_STATE="$fake_state" \
  bash "$script_dir/install.sh" \
    --token 'test-only-secret' \
    --nodes '2,7' \
    --data-dir "$data_dir"
)"

grep -Fq 'Kernel:     xray' <<< "$output"
grep -Fq 'Nodes (2): 2 7' <<< "$output"
grep -Fq 'Proxy PP:   ready' <<< "$output"
grep -Fq 'sha256:ae789704e2f6e90e812e926a37e83a5e3e8cdce4dbdd93b8b72414f0defac6ad' <<< "$output"
if grep -Fq 'test-only-secret' <<< "$output"; then
  printf '部署输出泄露了Token。\n' >&2
  exit 1
fi
grep -Fq 'type: "xray"' "$data_dir/config.yml"
grep -Fq 'node_id: 2' "$data_dir/config.yml"
grep -Fq 'node_id: 7' "$data_dir/config.yml"
[[ "$(stat -c '%a' "$data_dir/config.yml")" == '600' ]]
[[ "$(stat -c '%a' "$data_dir/credentials.env")" == '600' ]]

printf 'Polaris Xboard-Node installer contract test passed\n'
