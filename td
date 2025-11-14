#!/usr/bin/env bash
# td v2.0 - 精简版 DERP 管理工具（交互式）
set -euo pipefail
export LANG=zh_CN.UTF-8

# Colors
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

DERP_SERVICE="derper"
TAILSCALE_SERVICE="tailscaled"
DERP_CERTDIR="/var/lib/derper/certs"
DERP_SYSTEMD_UNIT="/etc/systemd/system/derper.service"
DERPMAP_PATH="/etc/tailscale/derpmap.json"
CRON_FILE="/etc/cron.d/derper-renew"

_pause(){ read -rp $'\n按回车返回菜单'; }

# 解析 ExecStart 中的 hostname
get_derp_hostname(){
    if [[ -f "${DERP_SYSTEMD_UNIT}" ]]; then
        awk -F'--hostname ' '/ExecStart/ {print $2; exit}' "${DERP_SYSTEMD_UNIT}" | awk '{print $1}' || true
    else
        echo ""
    fi
}

DERP_DEFAULT_HOSTNAME="$(get_derp_hostname)"
DERP_IP="$(dig +short "${DERP_DEFAULT_HOSTNAME:-}" A 2>/dev/null | tail -n1 || true)"

show_header(){
    clear
    echo -e "${CYAN}=== td v2.0 — DERP 管理工具 ===${RESET}"
    echo
}

menu(){
    show_header
    echo "1) 查看 DERP 服务状态"
    echo "2) 重启 DERP（并显示状态与日志）"
    echo "3) 停止 DERP（并显示状态）"
    echo "4) 生成 DERP Map（在界面显示，便于复制）"
    echo "5) 查看证书与到期时间"
    echo "6) 卸载本项目（彻底、带备份）"
    echo "0) 退出"
    echo
    read -rp "请选择: " opt
    case "$opt" in
        1) status_derp ;;
        2) restart_derp ;;
        3) stop_derp ;;
        4) gen_derpmap ;;
        5) show_cert ;;
        6) uninstall_project ;;
        0) exit 0 ;;
        *) echo "无效选项"; _pause; menu ;;
    esac
}

status_derp(){
    show_header
    echo -e "${CYAN}-- DERP 服务状态 --${RESET}"
    if systemctl status "${DERP_SERVICE}" >/dev/null 2>&1; then
        systemctl status "${DERP_SERVICE}" --no-pager || true
        echo
        echo -e "${CYAN}最后 20 行日志:${RESET}"
        journalctl -u "${DERP_SERVICE}" -n 20 --no-pager || true
    else
        warn "未检测到 ${DERP_SERVICE}.service"
    fi
    _pause; menu
}

restart_derp(){
    show_header
    info "正在重启 ${DERP_SERVICE}..."
    if systemctl cat "${DERP_SERVICE}" >/dev/null 2>&1; then
        sudo systemctl restart "${DERP_SERVICE}" || warn "重启失败"
        sleep 1
        echo
        echo -e "${CYAN}最新状态:${RESET}"
        systemctl status "${DERP_SERVICE}" --no-pager || true
        echo
        echo -e "${CYAN}最近 20 行日志:${RESET}"
        journalctl -u "${DERP_SERVICE}" -n 20 --no-pager || true
    else
        err "未找到 ${DERP_SERVICE}.service"
    fi
    _pause; menu
}

stop_derp(){
    show_header
    info "正在停止 ${DERP_SERVICE}..."
    if systemctl cat "${DERP_SERVICE}" >/dev/null 2>&1; then
        sudo systemctl stop "${DERP_SERVICE}" || warn "停止失败"
        sleep 1
        echo
        echo -e "${CYAN}当前服务状态:${RESET}"
        systemctl status "${DERP_SERVICE}" --no-pager || true

        if systemctl is-active --quiet "${DERP_SERVICE}"; then
            warn "服务仍在运行，可能被自动重启"
        else
            info "已停止"
        fi
    else
        warn "未检测到 ${DERP_SERVICE}.service"
    fi
    _pause; menu
}

is_ipv4(){
    local ip=$1
    if [[ -z "$ip" ]]; then return 1; fi
    if echo "$ip" | grep -E -q '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        IFS='.' read -r a b c d <<< "$ip"
        for x in $a $b $c $d; do
            (( x>=0 && x<=255 )) || return 1
        done
        return 0
    fi
    return 1
}

gen_derpmap(){
    show_header
    echo -e "${CYAN}生成完整 DERP ACL JSON（可直接替换控制台全部内容）${RESET}"

    # ---------------------------
    # 自动检测默认 Region 值
    # ---------------------------
    read -rp "RegionID（默认: 900，回车采用，输入修改）: " regionid
    regionid=${regionid:-900}

    read -rp "RegionCode（默认: CN，回车采用，输入修改）: " regioncode
    regioncode=${regioncode:-CN}

    read -rp "RegionName（默认: DERP-CN，回车采用，输入修改）: " regionname
    regionname=${regionname:-"DERP-CN"}

    # ---------------------------
    # 自动检测 DERP 主机名
    # 优先顺序：
    #   1. systemd --hostname
    #   2. /etc/letsencrypt/live/*
    #   3. fallback: derp.example.com
    # ---------------------------
    detect_hostname=""

    # 1) 从 systemd 取
    detect_hostname=$(get_derp_hostname || true)

    # 2) 从证书目录 fallback
    if [[ -z "$detect_hostname" ]]; then
        le_dir=$(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)
        if [[ -n "$le_dir" ]]; then
            detect_hostname=$(basename "$le_dir")
        fi
    fi

    # 3) fallback
    detect_hostname=${detect_hostname:-"derp.example.com"}

    read -rp "DERP 主机名（默认: ${detect_hostname}，回车采用，输入修改）: " host
    host=${host:-$detect_hostname}

    # ---------------------------
    # 自动检测公网 IPv4
    #   优先从 DNS 解析 hostname
    #   再 fallback 公网 IP
    # ---------------------------
    ip_from_dns=$(dig +short "$host" A 2>/dev/null | tail -n1)
    if [[ -n "$ip_from_dns" ]]; then
        default_ip="$ip_from_dns"
    else
        # fallback：获取真实公网 IP
        default_ip=$(curl -4s https://ipinfo.io/ip 2>/dev/null)
        # 再 fallback：hostname -I
        default_ip=${default_ip:-$(hostname -I | awk '{print $1}')}
    fi
    default_ip=${default_ip:-"0.0.0.0"}

    read -rp "DERP IPv4（默认: ${default_ip}，回车采用，输入修改）: " ip
    ip=${ip:-$default_ip}

    # ---------------------------
    # 输出完整 ACL JSON
    # ---------------------------
cat <<EOF

================================================================================
⚠ 请复制下面所有内容，并粘贴到控制台中完全替换当前 JSON！
控制台链接：
👉 https://login.tailscale.com/admin/acls/file

这是一个完整可用的 ACL + DERP Map 配置文件，保存即可立即生效。
================================================================================


{
  "derpMap": {
    "OmitDefaultRegions": true,
    "Regions": {
      "${regionid}": {
        "RegionID": ${regionid},
        "RegionCode": "${regioncode}",
        "RegionName": "${regionname}",
        "Nodes": [
          {
            "Name": "${host}",
            "RegionID": ${regionid},
            "HostName": "${host}",
            "IPv4": "${ip}",
            "STUNPort": 3478,
            "DERPPort": 443
          }
        ]
      }
    }
  },

  "acls": [
    {
      "action": "accept",
      "src": ["*"],
      "dst": ["*:*"]
    }
  ],

  "ssh": []
}

================================================================================
⚠ 完整 JSON 到此结束。
粘贴 → 保存 → 立即生效
================================================================================

EOF

    _pause
    menu
}

show_cert(){
    show_header
    echo -e "${CYAN}证书检测（DERP 使用证书 + Let’s Encrypt 源证书）${RESET}"
    local found=0

    # --- 将 openssl 日期转换为中文时间（北京时间） ---
    format_cn_time(){
        raw="$1"
        date -d "$raw" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$raw"
    }

    # --- 计算过期天数 ---
    calc_days_remaining(){
        end_raw="$1"
        end_ts=$(date -d "$end_raw" +%s 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        echo $(( (end_ts - now_ts) / 86400 ))
    }

    # --- 输出证书信息（主体 + 时间 + 剩余天数） ---
    print_cert_info(){
        cert_file="$1"

        # 提取必需字段
        subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')

        nb_raw=$(openssl x509 -in "$cert_file" -noout -startdate 2>/dev/null | cut -d= -f2)
        na_raw=$(openssl x509 -in "$cert_file" -noout -enddate   2>/dev/null | cut -d= -f2)

        nb_cn=$(format_cn_time "$nb_raw")
        na_cn=$(format_cn_time "$na_raw")

        days_left=$(calc_days_remaining "$na_raw")

        # 颜色提示
        if (( days_left < 0 )); then
            status="${RED}已过期！${RESET}"
        elif (( days_left <= 7 )); then
            status="${RED}即将过期（剩余 ${days_left} 天）${RESET}"
        elif (( days_left <= 30 )); then
            status="${YELLOW}安全期较短（剩余 ${days_left} 天）${RESET}"
        else
            status="${GREEN}安全（剩余 ${days_left} 天）${RESET}"
        fi

        echo -e "${CYAN}证书文件:${RESET} $cert_file"
        echo -e "  主体信息: ${subject}"
        echo -e "  生效时间: ${nb_cn}"
        echo -e "  到期时间: ${na_cn}"
        echo -e "  当前状态: ${status}"
        echo
    }

    # ---------------------------
    # 1) 检测 DERP 实际使用证书 (/etc/derp/certs)
    # ---------------------------
    if [[ -d "/etc/derp/certs" ]]; then
        certs=(/etc/derp/certs/*.crt)
        if [[ -e "${certs[0]}" ]]; then
            info "检测到 DERP 使用的证书目录: /etc/derp/certs"
            for c in /etc/derp/certs/*.crt; do
                print_cert_info "$c"
            done
            found=1
        fi
    fi

    # ---------------------------
    # 2) 检测 Let’s Encrypt 证书
    # ---------------------------
    if compgen -G "/etc/letsencrypt/live/*/fullchain.pem" >/dev/null; then
        for p in /etc/letsencrypt/live/*/fullchain.pem; do
            domain=$(basename "$(dirname "$p")")
            echo -e "${CYAN}检测到 Let’s Encrypt 源证书: $domain${RESET}"
            print_cert_info "$p"
            found=1
        done
    fi

    # ---------------------------
    # 3) 兼容旧版 derper certdir
    # ---------------------------
    if [[ -d "/var/lib/derper/certs" ]]; then
        certs2=(/var/lib/derper/certs/*.crt)
        if [[ -e "${certs2[0]}" ]]; then
            info "检测到 /var/lib/derper/certs 中的证书"
            for c in /var/lib/derper/certs/*.crt; do
                print_cert_info "$c"
            done
            found=1
        fi
    fi

    # ---------------------------
    # 无证书
    # ---------------------------
    if [[ $found -eq 0 ]]; then
        warn "未检测到任何证书（DERP / Let’s Encrypt）"
    fi

    _pause; menu
}

uninstall_project(){
    show_header
    echo -e "${YELLOW}本操作将彻底卸载本项目，并清理所有相关文件（包括 Go、Certbot、DERP）。${RESET}"
    echo -e "${YELLOW}注意：卸载后系统将立即重启！${RESET}"
    echo
    read -rp "请输入 yes 确认卸载: " yn
    [[ "$yn" != "yes" ]] && { info "已取消卸载"; _pause; menu; }

    echo
    info "开始卸载本项目..."

    #############################
    # 1. 停止 derper 服务
    #############################
    if systemctl status "$DERP_SERVICE" >/dev/null 2>&1; then
        info "停止 derper 服务..."
        systemctl stop "$DERP_SERVICE" 2>/dev/null || true
        systemctl disable "$DERP_SERVICE" 2>/dev/null || true
    else
        warn "未检测到 derper.service（可能已删除）"
    fi

    #############################
    # 2. 删除 derper systemd 单元
    #############################
    if [[ -f "$DERP_SYSTEMD_UNIT" ]]; then
        info "删除 systemd 单元文件: $DERP_SYSTEMD_UNIT"
        rm -f "$DERP_SYSTEMD_UNIT"
    fi
    systemctl daemon-reload || true
    systemctl reset-failed || true

    #############################
    # 3. 删除 derper 文件与目录
    #############################
    for p in /usr/local/bin/derper /opt/derper /var/lib/derper; do
        if [[ -e "$p" ]]; then
            info "删除: $p"
            rm -rf "$p"
        fi
    done

    #############################
    # 4. 删除 derper 自动续期 cron
    #############################
    if [[ -f "/etc/cron.d/derper-auto-renew" ]]; then
        info "删除自动续期任务: /etc/cron.d/derper-auto-renew"
        rm -f /etc/cron.d/derper-auto-renew
    fi

    #############################
    # 5. 删除 derper deploy-hook
    #############################
    if [[ -f "/usr/local/bin/derp-cert-copy.sh" ]]; then
        info "删除证书同步脚本: /usr/local/bin/derp-cert-copy.sh"
        rm -f /usr/local/bin/derp-cert-copy.sh
    fi

    #############################
    # 6. 删除 DERP 证书目录（你定义的）
    #############################
    if [[ -d "/etc/derp/certs" ]]; then
        info "DERP 使用的证书目录：/etc/derp/certs"
        read -rp "是否删除该目录？(默认: 不删除，回车=保留，输入 yes 删除): " del_derp_cert
        if [[ "$del_derp_cert" == "yes" ]]; then
            rm -rf /etc/derp/certs
            info "已删除 /etc/derp/certs"
        else
            info "保留 /etc/derp/certs"
        fi
    fi

    #############################
    # 7. 删除 Certbot（默认删除，无需询问）
    #############################
    info "删除 Certbot（apt+插件）..."
    apt remove -y certbot >/dev/null 2>&1 || true
    apt autoremove -y >/dev/null 2>&1 || true

    # pip3 插件
    for mod in certbot certbot-dns-cloudflare certbot-dns-aliyun certbot-dns-dnspod; do
        pip3 uninstall -y "$mod" >/dev/null 2>&1 || true
    done

    #############################
    # 8. 删除 Let's Encrypt 域名证书（目录结构）
    #############################
    if [[ -d "/etc/letsencrypt/live" ]]; then
        echo
        warn "检测到 Let’s Encrypt 证书目录：/etc/letsencrypt"
        read -rp "是否删除整个 /etc/letsencrypt 下的证书？(回车=保留, 输入 yes=删除): " del_le
        if [[ "$del_le" == "yes" ]]; then
            rm -rf /etc/letsencrypt/{live,archive,renewal}
            info "已删除 Let’s Encrypt 证书目录"
        else
            info "保留 Let’s Encrypt 证书目录"
        fi
    fi

    #############################
    # 9. 删除 Go 环境（默认删除）
    #############################
    if [[ -d "/usr/local/go" ]]; then
        info "删除 Go 运行环境..."
        rm -rf /usr/local/go
    fi
    rm -f /etc/profile.d/99-go-path.sh >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true

    #############################
    # 10. 删除源码缓存
    #############################
    [[ -d "/tmp/tailscale-src" ]] && rm -rf /tmp/tailscale-src

    #############################
    # 11. 最后一步：删除 td 自身
    #############################
    info "删除 td 命令自身..."
    rm -f /usr/local/bin/td

    #############################
    # 12. 重启系统（强制，无询问）
    #############################
    echo
    echo -e "${GREEN}卸载完成！系统将立即重启。${RESET}"
    read -rp "按回车重启系统..."
    reboot
}

# main
menu
