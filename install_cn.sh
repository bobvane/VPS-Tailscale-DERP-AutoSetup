#!/usr/bin/env bash
# install_cn.sh v4.2 — Modular Version (段落1~3)

##############################################
# 第 1 段：全局行为与环境初始化区
##############################################

set -euo pipefail
export LANG=zh_CN.UTF-8

# 颜色定义（全局唯一标准）
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 日志输出函数
log()  { echo -e "${GREEN}[INFO]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
err()  { echo -e "${RED}[ERROR]${PLAIN} $1"; }

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

log "运行环境检测完成。未对系统做任何修改。"

##############################################
# 第 3 段：系统组件可选优化区（可跳过）
##############################################

echo -e "${BLUE}即将进行系统优化操作，可提升网络质量与证书申请成功率。${PLAIN}"
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

    ##############################################
    # 3.2 修复 DNS 为国内源（阿里云特别处理）
    ##############################################

    fix_dns() {
        log "正在检测 DNS 配置..."

        # 当前 resolv.conf 真实路径
        local resolv_path
        resolv_path="$(readlink -f /etc/resolv.conf)"

        # 推荐国内 DNS
        local CN_DNS_V4_1="223.5.5.5"
        local CN_DNS_V4_2="183.60.83.19"
        local CN_DNS_V6_1="2400:3200::1"
        local CN_DNS_V6_2="2400:da00::6666"

        # 判断是否为 systemd-resolved 管理（软链接）
        if [[ -L /etc/resolv.conf ]]; then
            warn "检测到 resolv.conf 为符号链接（systemd-resolved 管理）。"
            warn "在阿里云环境下这会导致 DNS 被强制覆盖为 100.100.2.136，影响证书申请与 DERP。"

            read -p "是否切换到手动 DNS 管理（推荐）？[Y/n]: " ans
            ans=${ans:-Y}

            if [[ "$ans" =~ ^[Yy]$ ]]; then
                log "正在禁用 systemd-resolved ..."
                systemctl disable systemd-resolved >/dev/null 2>&1 || true
                systemctl stop systemd-resolved >/dev/null 2>&1 || true

                log "移除 resolv.conf 符号链接..."
                rm -f /etc/resolv.conf

                log "写入推荐国内 DNS..."
                cat >/etc/resolv.conf <<EOF
nameserver $CN_DNS_V4_1
nameserver $CN_DNS_V4_2
nameserver $CN_DNS_V6_1
nameserver $CN_DNS_V6_2
EOF

                log "锁定 resolv.conf（防止阿里云覆盖）..."
                chattr +i /etc/resolv.conf >/dev/null 2>&1 || true

                log "DNS 已成功切换为手动模式。"
            else
                warn "用户选择保留 systemd-resolved，不修改 DNS。"
            fi

            return
        fi

        # 非软链情况 → 读取当前 DNS 内容
        current_dns=$(cat /etc/resolv.conf 2>/dev/null || echo "")

        if echo "$current_dns" | grep -q "100.100."; then
            warn "检测到阿里云内部 DNS（100.100.x.x），将导致证书申请失败！"
            log "正在强制修复 DNS..."

            chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
            cat >/etc/resolv.conf <<EOF
nameserver $CN_DNS_V4_1
nameserver $CN_DNS_V4_2
nameserver $CN_DNS_V6_1
nameserver $CN_DNS_V6_2
EOF
            chattr +i /etc/resolv.conf >/dev/null 2>&1 || true

            log "已修复为国内 DNS,阿里云内部 DNS 已屏蔽。"
            return
        fi

        # 检查是否已经是国内 DNS
        if echo "$current_dns" | grep -Eq "$CN_DNS_V4_1|$CN_DNS_V4_2"; then
            log "当前 DNS 已为推荐国内 DNS，无需修改。"
            return
        fi

        # 国外 DNS → 询问是否替换
        warn "检测到当前 DNS 不是国内 DNS（可能为 8.8.8.8 / 1.1.1.1 等）。"
        read -p "是否替换为中国高可用 DNS？[Y/n]: " fix
        fix=${fix:-Y}

        if [[ "$fix" =~ ^[Yy]$ ]]; then
            chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
            log "正在写入国内 DNS..."
            cat >/etc/resolv.conf <<EOF
nameserver $CN_DNS_V4_1
nameserver $CN_DNS_V4_2
nameserver $CN_DNS_V6_1
nameserver $CN_DNS_V6_2
EOF
            chattr +i /etc/resolv.conf >/dev/null 2>&1 || true

            log "DNS 已成功修改为国内 DNS。"
        else
            warn "已跳过 DNS 修改。"
        fi
    }

    # 执行 DNS 修复
    fix_dns

    ###########################
    # 3.3 智能检测并自动启用 BBR（含 XanMod v3→v2→v1 自动fallback）
    ###########################

    log "== 开始 BBR 智能检测与自动启用流程 =="

    # 版本比较函数
    ver_ge() {
        [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
    }

    KERNEL_FULL=$(uname -r)
    KERNEL_MAJMIN=$(echo "$KERNEL_FULL" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    log "检测到内核：$KERNEL_FULL (简化版: $KERNEL_MAJMIN)"

    # 确保 iproute2 存在
    if ! command -v tc >/dev/null 2>&1; then
        warn "缺少 iproute2，正在自动安装..."
        apt update -y
        apt install -y iproute2
    fi

    # 获取 BBR 相关信息
    AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "none")
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")

    log "系统支持的 congestion control: ${AVAILABLE_CC:-(unknown)}"
    log "当前 default_qdisc: $CURRENT_QDISC, tcp_congestion_control: $CURRENT_CC"

    # 内核模块测试
    try_mod() { modprobe "$1" 2>/dev/null || true; }

    try_mod tcp_bbr2
    HAS_BBR2=false
    if echo "$AVAILABLE_CC" | grep -qw "bbr2"; then
        HAS_BBR2=true
    else
        AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
        [[ "$AVAILABLE_CC" =~ bbr2 ]] && HAS_BBR2=true
    fi

    try_mod tcp_bbr
    HAS_BBR1=false
    if echo "$AVAILABLE_CC" | grep -qw "bbr"; then
        HAS_BBR1=true
    fi

    try_mod sch_fq_codel
    HAS_FQ_CODEL=false
    if modprobe -n sch_fq_codel >/dev/null 2>&1 || tc qdisc show | grep -qi fq_codel; then
        HAS_FQ_CODEL=true
    fi

    HAS_FQ=true

    log "检测结果：BBRv2=$HAS_BBR2, BBR1=$HAS_BBR1, fq_codel=$HAS_FQ_CODEL"

    MIN_BBR2="5.9"
    KERNEL_SUPPORTS_BBR2=false
    if ver_ge "$KERNEL_MAJMIN" "$MIN_BBR2"; then
        KERNEL_SUPPORTS_BBR2=true
    fi

    log "内核是否满足 BBRv2 最低版本 ($MIN_BBR2)：$KERNEL_SUPPORTS_BBR2"

    ENABLED_MODE="none"

    # sysctl helper
    sysctl_write() {
        local key="$1"
        local value="$2"
        sed -i "/^${key//./\\.}=/d" /etc/sysctl.conf || true
        echo "${key}=${value}" >> /etc/sysctl.conf
    }

    ########################################
    # 优先级1：BBRv2 + fq_codel（当前内核支持并已编译）
    ########################################
    if $HAS_BBR2 && $HAS_FQ_CODEL && $KERNEL_SUPPORTS_BBR2; then
        log "优先级1 满足 → 启用 BBRv2 + fq_codel"

        sysctl_write net.core.default_qdisc fq
        sysctl_write net.ipv4.tcp_congestion_control bbr2
        sysctl -p >/dev/null 2>&1

        for IF in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
            tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
        done

        CUR=$(sysctl -n net.ipv4.tcp_congestion_control)
        [[ "$CUR" == "bbr2" ]] && ENABLED_MODE="BBRv2 + fq_codel"
    fi

    ########################################
    # 优先级2：BBRv2 + fq
    ########################################
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR2 && $KERNEL_SUPPORTS_BBR2; then
        log "优先级2 满足 → 启用 BBRv2 + fq"

        sysctl_write net.core.default_qdisc fq
        sysctl_write net.ipv4.tcp_congestion_control bbr2
        sysctl -p >/dev/null 2>&1

        CUR=$(sysctl -n net.ipv4.tcp_congestion_control)
        [[ "$CUR" == "bbr2" ]] && ENABLED_MODE="BBRv2 + fq"
    fi

    #######################################################################
    # 如果 BBRv2 不支持 → 尝试安装 XanMod 内核（支持 v3→v2→v1 三层 fallback）
    #######################################################################
    if [[ "$ENABLED_MODE" == "none" ]] && ! $HAS_BBR2; then

        log "检测到系统不支持 BBRv2，准备进行 XanMod 内核自动检测与安装..."

        # 检测 avx2 指令集
        CPU_SUPPORTS_AVX2=false
        if grep -qi avx2 /proc/cpuinfo; then
            CPU_SUPPORTS_AVX2=true
        fi

        # 选择优先版本
        if $CPU_SUPPORTS_AVX2; then
            DEFAULT_XANMOD="linux-xanmod-x64v3"
        else
            DEFAULT_XANMOD="linux-xanmod-x64v2"
        fi

        # 候选版本
        XANMOD_CANDIDATES=(
            "$DEFAULT_XANMOD"
            "linux-xanmod-x64v2"
            "linux-xanmod-x64v1"
        )

        # 检测仓库是否可访问
        if curl -fsSL --connect-timeout 5 https://dl.xanmod.org >/dev/null 2>&1; then
            echo -e "\033[33m[建议] 安装 XanMod 内核可启用 BBRv2，显著提升 DERP 性能。\033[0m"
            read -rp "是否安装 XanMod 内核？ [Y/n]: " CONF_XANMOD
            CONF_XANMOD=${CONF_XANMOD:-Y}

            if [[ "$CONF_XANMOD" =~ ^[Yy]$ ]]; then
                log "开始尝试安装 XanMod 内核（含 v3→v2→v1 自动 fallback）..."

                # 安装 GPG key
                curl -fsSL https://dl.xanmod.org/archive.key \
                    | gpg --dearmor -o /usr/share/keyrings/xanmod.gpg

                # 添加仓库
                echo "deb [signed-by=/usr/share/keyrings/xanmod.gpg] http://deb.xanmod.org releases main" \
                    | tee /etc/apt/sources.list.d/xanmod.list

                apt update -y

                # 依次尝试三种内核包
                XANMOD_INSTALLED=false
                for PKG in "${XANMOD_CANDIDATES[@]}"; do
                    log "尝试安装：$PKG ..."
                    if apt install -y "$PKG"; then
                        log "成功安装 XanMod 内核：$PKG"
                        XANMOD_INSTALLED=true
                        break
                    else
                        warn "$PKG 安装失败，尝试 fallback..."
                    fi
                done

                if ! $XANMOD_INSTALLED; then
                    warn "XanMod 所有版本均安装失败 → 启用优先级3（BBR1 + fq_codel）"
                fi
            fi
        else
            warn "无法访问 XanMod 仓库 → 自动跳过内核升级"
        fi
    fi

    ########################################
    # 优先级3：BBR1 + fq_codel（兜底永远可用）
    ########################################
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR1 && $HAS_FQ_CODEL; then
        log "优先级3 满足 → 启用 BBR1 + fq_codel"

        sysctl_write net.core.default_qdisc fq
        sysctl_write net.ipv4.tcp_congestion_control bbr
        sysctl -p >/dev/null 2>&1

        for IF in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
            tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
        done

        CUR=$(sysctl -n net.ipv4.tcp_congestion_control)
        [[ "$CUR" == "bbr" ]] && ENABLED_MODE="BBR1 + fq_codel"
    fi

    ########################################
    # 输出最终结果
    ########################################
    if [[ "$ENABLED_MODE" != "none" ]]; then
        log "BBR 优化完成：$ENABLED_MODE"
    else
        warn "无法启用 BBR1 或 BBR2。建议检查内核后重新运行脚本。"
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

    ##############################################
    # 3.5 Sysctl 网络优化（DERP + XanMod 专用）
    ##############################################

    log "应用 DERP 优化专用 sysctl 配置..."

cat >/etc/sysctl.d/99-derp-opt.conf <<EOF
# 低延迟 UDP 优化（DERP 主流量）
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000

# 减少 UDP 丢包（适用于中高端 VPS）
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 允许更多临时端口（DERP 需大量短连接）
net.ipv4.ip_local_port_range = 10000 65535

# Keepalive 频率（避免 NAT 提前清理）
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 禁止 rp_filter 降低延迟
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# 关闭 ICMP 限速（DERP 中 Ping 用作调度）
net.ipv4.icmp_ratelimit = 0

# 高性能队列调度（XanMod 使用 fq 默认即可）
net.core.default_qdisc = fq
EOF

    sysctl --system >/dev/null 2>&1 || true
    log "Sysctl 网络优化已应用（DERP + XanMod 专用）。"


    log "前 3 段执行完毕，脚本即将进入证书申请与 DERP 主程序安装部分。"


