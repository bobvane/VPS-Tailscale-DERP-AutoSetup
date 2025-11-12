#!/usr/bin/env bash
# td - DERP 管理菜单工具
set -e

show_menu(){
  clear
  echo "==========================================="
  echo " Tailscale DERP 管理工具"
  echo "-------------------------------------------"
  echo " 1. 启动 DERP 服务"
  echo " 2. 停止 DERP 服务"
  echo " 3. 重启 DERP 服务"
  echo " 4. 查看运行状态"
  echo " 5. 修改绑定域名"
  echo " 6. 修改监听端口"
  echo " 7. 重新申请 SSL 证书"
  echo " 8. 手动更新 derper/tailscale"
  echo " 9. 查看日志"
  echo "10. 退出"
  echo "==========================================="
  read -rp "请输入选项 [1-10]: " c
}

while true; do
  show_menu
  case "$c" in
    1) systemctl start derper ;;
    2) systemctl stop derper ;;
    3) systemctl restart derper ;;
    4) systemctl status derper --no-pager -l ;;
    5) read -rp "新域名: " nd; sed -i "s/--hostname .*/--hostname ${nd} --certmode letsencrypt --stun --a \":443\"/" /etc/systemd/system/derper.service; systemctl daemon-reload; systemctl restart derper ;;
    6) read -rp "新端口: " np; sed -i "s/--a \\\":.*\\\"/--a \\\":${np}\\\"/" /etc/systemd/system/derper.service; systemctl daemon-reload; systemctl restart derper ;;
    7) rm -rf /var/lib/derper-certs; systemctl restart derper ;;
    8) /usr/local/bin/derper-autoupdate.sh ;;
    9) journalctl -u derper -n 200 --no-pager ;;
    10) exit 0 ;;
    *) echo "无效选项" ;;
  esac
  read -rp "按回车继续..."
done

