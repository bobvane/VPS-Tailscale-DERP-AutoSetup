#!/bin/bash
# Tailscale DERP 管理菜单 td

CONFIG_FILE="/opt/derper/derper.conf"
DERP_MAP="/opt/derper/derpmap.json"
SERVICE_FILE="/etc/systemd/system/derper.service"

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# 保存配置
save_config() {
    mkdir -p /opt/derper
    cat > "$CONFIG_FILE" <<EOF
DOMAIN="$DOMAIN"
ENABLE_IPV6="$ENABLE_IPV6"
DERP_PORT="$DERP_PORT"
STUN_PORT="$STUN_PORT"
EOF
}

# 生成 derpmap.json
gen_derpmap() {
    mkdir -p /opt/derper
    cat > "$DERP_MAP" <<EOF
{
  "Regions": {
    "901": {
      "RegionID": 901,
      "RegionCode": "custom",
      "Nodes": [
        {
          "Name": "my-derp",
          "RegionID": 901,
          "HostName": "$DOMAIN",
          "IPv4": "",
          "IPv6": "",
          "DERPPort": $DERP_PORT,
          "STUNPort": $STUN_PORT
        }
      ]
    }
  }
}
EOF
}

# 安装 derper
install_derper() {
    echo "[INFO] 安装 DERP 服务器..."

    mkdir -p /opt/derper
    cd /opt/derper || exit

    curl -L -o derper https://tailscale.com/dist/derper/derper-linux-amd64
    chmod +x derper

    gen_derpmap

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tailscale DERP Server
After=network.target

[Service]
ExecStart=/opt/derper/derper --hostname=$DOMAIN --certdir=/etc/letsencrypt/live/$DOMAIN \
  --certmode=manual --derp-map-file=$DERP_MAP --stun-port=$STUN_PORT --derp-port=$DERP_PORT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now derper

    echo "DERP 安装完成！"
}

# 卸载 DERP
uninstall_derper() {
    systemctl stop derper
    systemctl disable derper
    rm -f "$SERVICE_FILE"
    rm -rf /opt/derper
    systemctl daemon-reload
    echo "DERP 已卸载完成。"
}

# 修改配置
menu_config() {
    echo "当前配置："
    read_config
    echo "域名: $DOMAIN"
    echo "IPv6: $ENABLE_IPV6"
    echo "DERP 端口: $DERP_PORT"
    echo "STUN 端口: $STUN_PORT"

    echo
    read -rp "输入新域名 (留空则不变): " new_domain
    read -rp "开启 IPv6? (1=是, 0=否, 默认保持): " new_ipv6
    read -rp "DERP 端口 (默认443): " new_derp
    read -rp "STUN 端口 (默认3478): " new_stun

    [ -n "$new_domain" ] && DOMAIN="$new_domain"
    [ -n "$new_ipv6" ] && ENABLE_IPV6="$new_ipv6"
    [ -n "$new_derp" ] && DERP_PORT="$new_derp"
    [ -n "$new_stun" ] && STUN_PORT="$new_stun"

    save_config
    echo "配置已保存。"
}

# 查看日志
show_logs() {
    journalctl -u derper -f
}

# 主菜单
main_menu() {
    clear
    echo "=========================="
    echo "  Tailscale DERP 管理菜单"
    echo "=========================="
    echo "1. 安装 DERP"
    echo "2. 卸载 DERP"
    echo "3. 修改配置"
    echo "4. 重启 DERP"
    echo "5. 查看 DERP 状态"
    echo "6. 查看日志"
    echo "0. 退出"
    echo "=========================="

    read -rp "请选择选项: " choice

    case "$choice" in
        1) install_derper ;;
        2) uninstall_derper ;;
        3) menu_config ;;
        4) systemctl restart derper && echo "已重启" ;;
        5) systemctl status derper ;;
        6) show_logs ;;
        0) exit 0 ;;
        *) echo "无效选项";;
    esac
}

read_config
main_menu
