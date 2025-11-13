#!/usr/bin/env bash
# install_cn.sh v4.2 — Modular Version (段落1~3)

##############################################
# 第 1 段：全局行为与环境初始化区
##############################################

set -euo pipefail
export LANG=zh_CN.UTF-8

# 颜色输出函数（后续各段都需要用）
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[36m"; NC="\033[0m"

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

log "脚本已启动（install_cn.sh），加载全局环境完成。"

##############################################
# 第 2 段：运行环境检查区（非破坏性）
##############################################

# 必须 root
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此脚本。"
    exit 1
fi

# 检查系统类型
if ! grep -qiE "debian|ubuntu" /etc/os-release; then
    err "当前系统不是 Debian/Ubuntu，不支持中国优化版 install_cn.sh。"
    exit 1
fi

OS=$(grep "^ID=" /etc/os-release | cut -d= -f2)
VERSION=$(grep "VERSION_ID" /etc/os-release | cut -d= -f2 | tr -d '"')

log "系统检测：$OS $VERSION"

# 检查 80 和 443 是否被占用
for PORT in 80 443; do
    if ss -tulnp | grep -q ":$PORT "; then
        warn "端口 $PORT 被占用，可能影响证书申请。"
        ss -tulnp | grep ":$PORT "
    fi
done

# 检查 DNS 是否为阿里云的"内部 DNS"，可能屏蔽证书解析
ALI_DNS_1="100.100.2.136"
ALI_DNS_2="100.100.2.138"

CURRENT_DNS=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)

if echo "$CURRENT_DNS" | grep -qE "$ALI_DNS_1|$ALI_DNS_2"; then
    warn "检测到阿里云内部 DNS（$CURRENT_DNS），可能导致 Let’s Encrypt 证书申请失败。"
fi

log "运行环境检测完成。未对系统做任何修改。"

##############################################
# 第 3 段：系统组件可选优化区（可跳过）
##############################################

echo -e "${BLUE}即将进行系统优化操作，可提升网络质量与证书申请成功率。${NC}"
echo "内容包括："
echo "1) 更新系统与安装必要组件"
echo "2) 设置国内高可用 DNS (223.5.5.5 / 183.60.83.19 等)"
echo "3) 开启 BBR 加速"
echo "4) 创建 1GB Swap（若无）"
echo "5) 应用网络与内核优化 sysctl 参数"

read -rp "是否继续执行以上优化？ [Y/n]: " CONF_OPT_ALL
CONF_OPT_ALL=${CONF_OPT_ALL:-Y}

if [[ ! "$CONF_OPT_ALL" =~ ^[Yy]$ ]]; then
    warn "用户选择跳过所有系统优化步骤。"
else
    log "开始执行系统优化..."

    ###########################
    # 3.1 更新系统 + 基础组件
    ###########################
    read -rp "是否更新系统并安装基础组件？ [Y/n]: " CONF_UPGRADE
    CONF_UPGRADE=${CONF_UPGRADE:-Y}
    if [[ "$CONF_UPGRADE" =~ ^[Yy]$ ]]; then
        log "正在更新系统并安装基础工具..."
        apt update -y
        apt install -y curl wget jq unzip socat
    fi

    ###########################
    # 3.2 修复 DNS 为国内源
    ###########################
    read -rp "是否将 DNS 修改为中国高可用 DNS？ [Y/n]: " CONF_DNS
    CONF_DNS=${CONF_DNS:-Y}
    if [[ "$CONF_DNS" =~ ^[Yy]$ ]]; then
        log "正在设置国内 DNS..."
        cat >/etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 183.60.83.19
nameserver 2400:3200::1
nameserver 2400:da00::6666
EOF
        chattr +i /etc/resolv.conf || true
        log "DNS 已设置为国内高可用源。"
    fi

    ###########################
    # 3.3 智能检测并自动启用 BBR（完全自动，启用日志/通知）
    # 优先顺序： 1) BBRv2 + fq_codel  2) BBRv2 + fq  3) BBR1 + fq_codel
    ###########################

    # helper: 比较版本（"major.minor.patch"），返回 0 if v1 >= v2
    ver_ge() {
      # usage: ver_ge "5.15.0" "5.9"
      [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
    }

    log "== 开始 BBR 智能检测与自动启用流程 =="

    # 基本信息
    KERNEL_RAW=$(uname -r)
    KERNEL_VER=$(echo "$KERNEL_RAW" | sed -E 's/([0-9]+)\.([0-9]+).*/\1.\2/')
    KERNEL_FULL=$(uname -r)
    log "检测到内核：$KERNEL_FULL (简化版: $KERNEL_VER)"

    # 确保必要工具存在
    if ! command -v tc >/dev/null 2>&1; then
      log "缺少 tc (iproute2)。尝试自动安装 iproute2..."
      apt update -y
      apt install -y iproute2 || warn "安装 iproute2 失败，部分 qdisc 操作可能不可用。"
    fi

    # 检查可用的 congestion control 列表
    AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    log "系统支持的 congestion control: ${AVAILABLE_CC:-(unknown)}"

    # 检查当前设置
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "none")
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
    log "当前 default_qdisc: $CURRENT_QDISC, tcp_congestion_control: $CURRENT_CC"

    # 尝试加载模块以检测是否可用（不会报错中断）
    try_mod() {
      modprobe "$1" 2>/dev/null || true
    }

    # 检测支持项
    # BBRv2 检测: 尝试 modprobe tcp_bbr2 并查看 available list 包含 bbr2
    try_mod tcp_bbr2
    HAS_BBR2=false
    if echo "$AVAILABLE_CC" | grep -qw "bbr2"; then
      HAS_BBR2=true
    else
      # re-read after modprobe
      AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
      if echo "$AVAILABLE_CC" | grep -qw "bbr2"; then
        HAS_BBR2=true
      fi
    fi

    # BBR1 检测
    try_mod tcp_bbr
    HAS_BBR1=false
    if echo "$AVAILABLE_CC" | grep -qw "bbr"; then
      HAS_BBR1=true
    else
      AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
      if echo "$AVAILABLE_CC" | grep -qw "bbr"; then
        HAS_BBR1=true
      fi
    fi

    # fq_codel 检测
    try_mod sch_fq_codel
    HAS_FQ_CODEL=false
    # if tc supports fq_codel qdisc by listing or modprobe success
    if modprobe -n sch_fq_codel >/dev/null 2>&1 || tc -s qdisc show 2>/dev/null | grep -qi fq_codel; then
      HAS_FQ_CODEL=true
    fi

    # fq 检测（通常内核内置）
    HAS_FQ=true  # fq 通常存在

    log "检测结果：BBRv2=$HAS_BBR2, BBR1=$HAS_BBR1, fq_codel=$HAS_FQ_CODEL"

    # 检查 kernel 是否满足 BBRv2 最低需求（保守阈值：5.9）
    MIN_BBR2="5.9"
    # parse kernel major.minor
    KERNEL_MAJMIN=$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    if ver_ge "$KERNEL_MAJMIN" "$MIN_BBR2"; then
      KERNEL_OK_FOR_BBR2=true
    else
      KERNEL_OK_FOR_BBR2=false
    fi

    log "内核是否满足 BBRv2 最低版本 ($MIN_BBR2) 要求: $KERNEL_OK_FOR_BBR2"

    # 如果内核太旧且是 Debian/Ubuntu，尝试安装 meta kernel（linux-image-amd64）
    if ! $KERNEL_OK_FOR_BBR2 && (grep -qiE "debian|ubuntu" /etc/os-release); then
      warn "内核版本过旧，BBRv2 可能不受支持。尝试安装最新内核 meta 包（需要重启生效）。"
      apt update -y
      # 安装 meta kernel 包（会安装适合系统的最新稳定内核），不重启
      if apt install -y linux-image-amd64 linux-headers-amd64 2>/dev/null; then
        log "已安装/更新内核包。注意：需要手动或脚本重启系统以加载新内核，重启后脚本可再次运行以启用 BBRv2。"
        # record a flag file so user或自动流程知道需要重启后再启用
        echo "kernel-upgrade-required-$(date +%s)" > /var/run/bbr_kernel_upgrade.flag || true
      else
        warn "安装内核 meta 包失败；若需要支持 BBRv2，请手动升级内核或联系管理员。"
      fi
    fi

    # 启用逻辑：按优先级尝试
    ENABLED_MODE="none"
    ENABLE_LOG_MSG=""

    # helper to write sysctl entries idempotently
    sysctl_write() {
      local key=$1 value=$2
      # remove existing lines
      sed -i "/^${key//./\\.}=.*/d" /etc/sysctl.conf || true
      echo "${key}=${value}" >> /etc/sysctl.conf
    }

    # 优先级1：BBRv2 + fq_codel
    if $HAS_BBR2 && $HAS_FQ_CODEL && $KERNEL_OK_FOR_BBR2; then
      log "优先级1 条件满足：尝试启用 BBRv2 + fq_codel"
      sysctl_write net.core.default_qdisc fq
      sysctl_write net.ipv4.tcp_congestion_control bbr2
      sysctl -p >/dev/null 2>&1 || true

      # apply fq_codel to all non-loopback interfaces (best-effort)
      for IF in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
      done

      # re-check
      CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
      if [[ "$CUR" == "bbr2" ]]; then
        ENABLED_MODE="BBRv2 + fq_codel"
        ENABLE_LOG_MSG="已启用 BBRv2 + fq_codel（优先级1）。"
      else
        warn "尝试启用 BBRv2 + fq_codel 未生效（可能需要重启或内核不完全支持）。"
      fi
    fi

    # 优先级2：BBRv2 + fq
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR2 && $KERNEL_OK_FOR_BBR2; then
      log "优先级2 条件满足：尝试启用 BBRv2 + fq"
      sysctl_write net.core.default_qdisc fq
      sysctl_write net.ipv4.tcp_congestion_control bbr2
      sysctl -p >/dev/null 2>&1 || true

      CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
      if [[ "$CUR" == "bbr2" ]]; then
        ENABLED_MODE="BBRv2 + fq"
        ENABLE_LOG_MSG="已启用 BBRv2 + fq（优先级2）。"
      else
        warn "尝试启用 BBRv2 + fq 未生效。"
      fi
    fi

    # 优先级3：BBR1 + fq_codel
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR1 && $HAS_FQ_CODEL; then
      log "优先级3 条件满足：尝试启用 BBR1 + fq_codel"
      sysctl_write net.core.default_qdisc fq
      sysctl_write net.ipv4.tcp_congestion_control bbr
      sysctl -p >/dev/null 2>&1 || true

      for IF in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
      done

      CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
      if [[ "$CUR" == "bbr" ]]; then
        ENABLED_MODE="BBR1 + fq_codel"
        ENABLE_LOG_MSG="已启用 BBR (BBR1) + fq_codel（优先级3）。"
      else
        warn "尝试启用 BBR1 + fq_codel 未生效。"
      fi
    fi

    # 若仍未启用，尝试 BBR1 + fq（备选，不主动选择为最终优先级，但作为容错尝试）
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR1; then
      log "尝试备用启用 BBR1 + fq（兼容性备选）"
      sysctl_write net.core.default_qdisc fq
      sysctl_write net.ipv4.tcp_congestion_control bbr
      sysctl -p >/dev/null 2>&1 || true
      CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
      if [[ "$CUR" == "bbr" ]]; then
        ENABLED_MODE="BBR1 + fq (fallback)"
        ENABLE_LOG_MSG="已启用 BBR1 + fq（fallback）。"
      fi
    fi

    # 假 BBR 检测（防止被面板或脚本误导）
    # 检查 available list 与当前一致性
    AVAIL=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    CURCC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
    if [[ "$CURCC" == "bbr2" && "$AVAIL" != *bbr2* ]]; then
      warn "检测到当前使用 bbr2，但系统 available list 中不包含 bbr2，可能为假 bbr2（或内核模块异常）。"
    fi
    if [[ "$CURCC" == "bbr" && "$AVAIL" != *bbr* ]]; then
      warn "检测到当前使用 bbr，但系统 available list 中不包含 bbr，可能为假 bbr（或内核模块异常）。"
    fi

    # 最终输出
    if [[ "$ENABLED_MODE" != "none" ]]; then
      log "BBR 优化完成：$ENABLED_MODE"
      log "$ENABLE_LOG_MSG"
    else
      err "未能自动启用优先级1-3 中的任一项。请检查内核与模块支持（或重启以加载新内核）。"
      if [[ -f /var/run/bbr_kernel_upgrade.flag ]]; then
        warn "脚本已尝试安装新内核包，但尚未重启。请重启系统后重新运行脚本以启用 BBRv2。"
      fi
    fi

    log "== BBR 智能模块执行结束 =="

    ###########################
    # 3.4 设置 Swap 1GB
    ###########################
    read -rp "是否创建 1GB Swap？ [Y/n]: " CONF_SWAP
    CONF_SWAP=${CONF_SWAP:-Y}
    if [[ "$CONF_SWAP" =~ ^[Yy]$ ]]; then
        if ! swapon --show | grep -q "swap"; then
            log "正在创建 1GB Swap..."
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
        else
            warn "系统已存在 Swap，跳过。"
        fi
    fi

    ###########################
    # 3.5 sysctl 内核优化
    ###########################
    read -rp "是否应用网络内核优化？ [Y/n]: " CONF_SYSCTL
    CONF_SYSCTL=${CONF_SYSCTL:-Y}
    if [[ "$CONF_SYSCTL" =~ ^[Yy]$ ]]; then
        log "正在应用网络优化参数..."
        cat >>/etc/sysctl.conf <<EOF
net.core.rmem_max=2500000
net.ipv4.tcp_fastopen=3
EOF
        sysctl -p
    fi

    log "所有系统优化操作已完成。"
fi

log "前 3 段执行完毕，脚本即将进入证书申请与 DERP 主程序安装部分。"

