#!/bin/bash
set -uo pipefail

LOG="/tmp/network_opt.log"
C_G='\033[0;32m'
C_Y='\033[1;33m'
C_R='\033[0;31m'
C_N='\033[0m'

prepare_log(){
  touch "$LOG" >/dev/null 2>&1 || LOG="/tmp/network_opt.$EUID.$$.log"
  touch "$LOG" >/dev/null 2>&1 || LOG="/dev/null"
  { : >>"$LOG"; } 2>/dev/null || LOG="/dev/null"
}

log_append(){
  { echo -e "$1" >>"$LOG"; } 2>/dev/null || true
}

i(){
  echo -e "${C_G}[INFO]${C_N} $*"
  log_append "[INFO] $*"
  return 0
}

w(){
  echo -e "${C_Y}[WARN]${C_N} $*"
  log_append "[WARN] $*"
  return 0
}

e(){
  echo -e "${C_R}[ERR ]${C_N} $*"
  log_append "[ERR ] $*"
  return 0
}

has(){
  command -v "$1" >/dev/null 2>&1
}

install_bbr(){
  i "配置BBR+FQ..."
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo x)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo x)"

  [[ "$cc" == "bbr" && "$qd" == "fq" ]] && i "BBR+FQ已生效" || w "BBR+FQ可能未完全生效"
}

configure_sysctl(){
  i "配置系统参数(AMD64)..."

  [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true

  cat > /etc/sysctl.conf <<'EOF'
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_syncookies = 1
net.core.rmem_max = 100000000
net.core.wmem_max = 100000000
net.ipv4.tcp_rmem = 8192 65536 100000000
net.ipv4.tcp_wmem = 8192 65536 100000000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 && i "sysctl应用成功" || w "sysctl应用异常"

  if has systemctl; then
    has apt-get && {
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq irqbalance >/dev/null 2>&1 || true
    }
    systemctl enable --now irqbalance >/dev/null 2>&1 || true
  fi
}

install_iperf3(){
  i "安装iperf3..."

  has apt-get || {
    w "未找到apt-get，跳过iperf3"
    return 1
  }

  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq >/dev/null 2>&1 || true
  has iperf3 || apt-get install -y -qq iperf3 >/dev/null 2>&1 || true

  if has systemctl && has iperf3; then
    cat > /etc/systemd/system/iperf3.service <<EOF
[Unit]
Description=iperf3 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v iperf3) -s -p 5201 --bind 0.0.0.0
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now iperf3 >/dev/null 2>&1 || true
  fi

  has iperf3 && i "iperf3安装完成" || w "iperf3安装可能失败"
}

install_btop(){
  i "安装btop..."

  has apt-get || {
    w "未找到apt-get，跳过btop"
    return 1
  }

  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq >/dev/null 2>&1 || true
  apt install -y btop >/dev/null 2>&1 || true

  has btop && i "btop安装完成" || w "btop安装可能失败"
}

main(){
  prepare_log

  if [[ $EUID -ne 0 ]]; then
    e "请用root执行，例如：curl -fsSL URL | sudo bash"
    exit 1
  fi

  i "[1/4] BBR"
  install_bbr || true

  sleep 2

  i "[2/4] sysctl"
  configure_sysctl || w "sysctl步骤异常"

  i "[3/4] iperf3"
  install_iperf3 || w "iperf3步骤异常"

  i "[4/4] btop"
  install_btop || w "btop步骤异常"

  i "全部任务完成"
}

main "$@"
