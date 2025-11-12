#!/usr/bin/env bash
# td v1.3 - VPS-Tailscale-DERP-AutoSetup 管理工具
set -e

green(){ echo -e "\033[1;32m$1\033[0m"; }
yellow(){ echo -e "\033[1;33m$1\033[0m"; }
red(){ echo -e "\033[1;31m$1\033[0m"; }

menu(){
  clear
  green "========= VPS-Tailscale-DERP 管理菜单 ========="
  echo "1. 查看 derper 状态"
  echo "2. 重启 derper 服务"
  echo "3. 停止 derper 服务"
  echo "4. 重新申请 SSL 证书"
  echo "5. 修改绑定域名"
  echo "6. 卸载此项目（彻底清理）"
  echo "0. 退出"
  echo "==============================================="
  read -rp "请选择操作: " choice

  case $choice in
    1) systemctl status derper ;;
    2) systemctl restart derper; green "✅ 已重启 derper" ;;
    3) systemctl stop derper; green "🛑 已停止 derper" ;;
    4) systemctl stop derper; rm -rf /root/.cache/letsencrypt; systemctl restart derper; green "🔄 SSL 证书已重新申请" ;;
    5) read -rp "输入新的域名: " newdom
       sed -i "s/--hostname .*/--hostname ${newdom} --certmode letsencrypt --stun --a \":443\"/" /etc/systemd/system/derper.service
       systemctl daemon-reload; systemctl restart derper
       green "✅ 已更新绑定域名为 ${newdom}" ;;
    6) uninstall ;;
    0) exit 0 ;;
    *) red "无效选项";;
  esac
  read -rp "按回车返回菜单..." temp
  menu
}

uninstall(){
  yellow "⚠️ 确认要彻底卸载 VPS-Tailscale-DERP 吗？(y/n)"
  read -rp "> " yn
  [[ "$yn" != "y" && "$yn" != "Y" ]] && return

  echo "🧹 正在卸载..."
  systemctl stop derper 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload
  rm -rf /opt/derper /tmp/tailscale-src /usr/local/bin/derper /usr/local/bin/derper-autoupdate.sh
  rm -rf /usr/local/go /tmp/go.tar.gz /etc/profile.d/go-path.sh
  sed -i '/go\/bin/d' ~/.bashrc 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
  apt remove -y tailscale tailscale-archive-keyring >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
  rm -f /usr/local/bin/td
  green "✅ 卸载完成，系统已清理干净。"
}

menu
