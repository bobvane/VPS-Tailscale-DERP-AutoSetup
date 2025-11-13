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

# 检查阿里云内部 DNS
ALI_INTERNAL_DNS=("100.100.2.136" "100.100.2.138")
CURRENT_DNS=$(grep -oE 'nameserver ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' \
                /run/systemd/resolve/resolv.conf 2>/dev/null | awk '{print $2}')

if [[ "${ALI_INTERNAL_DNS[*]}" =~ "$CURRENT_DNS" ]]; then
    echo -e "${RED}[WARN] 检测到阿里云内部 DNS：${CURRENT_DNS}${PLAIN}"
    echo -e "${YELLOW}[WARN] 阿里云会在重启后强制覆盖 DNS，可能导致 Let’s Encrypt 证书申请失败。${PLAIN}"
    read -p "是否将 DNS 修改为中国高可用 DNS（推荐，强烈建议）？[Y/n]: " dns_change
    dns_change=${dns_change:-Y}

    if [[ "$dns_change" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}[INFO] 正在禁用 systemd-resolved ...${PLAIN}"
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true

        echo -e "${BLUE}[INFO] 移除符号链接 /etc/resolv.conf ...${PLAIN}"
        rm -f /etc/resolv.conf

        echo -e "${BLUE}[INFO] 写入高可用 DNS ...${PLAIN}"
        cat >/etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 183.60.83.19
nameserver 2400:3200::1
nameserver 2400:da00::6666
EOF

        echo -e "${BLUE}[INFO] 锁定 /etc/resolv.conf 防止被覆盖 ...${PLAIN}"
        chattr +i /etc/resolv.conf || {
            echo -e "${RED}[ERROR] 无法锁定 resolv.conf，请检查文件系统类型。${PLAIN}"
        }

        echo -e "${GREEN}[SUCCESS] DNS 已成功固定，不再受到阿里云覆盖影响。${PLAIN}"
    fi
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
    read -rp "是否将 DNS 修改为中国高可用 DNS？（⚠ 强烈建议，否则 Let’s Encrypt 可能失败）  [Y/n]: " CONF_DNS
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
            echo -e "${YELLOW}[建议] 安装 XanMod 内核可启用 BBRv2，显著提升 DERP 性能。${NC}"
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

