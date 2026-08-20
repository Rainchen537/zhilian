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
  i "配置系统参数(Linode 1C2G)..."

  [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true

  cat > /etc/sysctl.conf <<'EOF'
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 1
kernel.core_pattern = core_%e
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.panic_on_oom = 1
vm.overcommit_memory = 1
vm.min_free_kbytes = 90214

net.core.default_qdisc = fq
net.core.netdev_max_backlog = 2000
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.core.somaxconn = 805
net.core.optmem_max = 65536

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 0

net.ipv4.tcp_rmem = 8192 87380 8388608
net.ipv4.tcp_wmem = 8192 65536 8388608
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 4
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0

net.ipv4.tcp_max_syn_backlog = 3223
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_syncookies = 1

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh1 = 1024

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
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
