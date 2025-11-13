#!/bin/bash
# === Let's Encrypt 连通性测试脚本 ===
set -e

HOST="acme-v02.api.letsencrypt.org"
PORT=443
PATH="/directory"

echo "=== 1. DNS 解析测试 ==="
echo "IPv4:"
dig +short A $HOST
echo "IPv6:"
dig +short AAAA $HOST

echo -e "\n=== 2. TCP 连通性测试 ==="
# IPv4
nc -zv -w 3 $(dig +short A $HOST | head -1) $PORT 2>&1 | grep -i succeeded && echo "IPv4 TCP OK" || echo "IPv4 TCP FAILED"
# IPv6（如果有）
[ -n "$(dig +short AAAA $HOST)" ] && nc -zv -w 3 $(dig +short AAAA $HOST | head -1) $PORT 2>&1 | grep -i succeeded && echo "IPv6 TCP OK" || echo "IPv6 TCP FAILED"

echo -e "\n=== 3. TLS 握手测试 ==="
# IPv4
echo | openssl s_client -connect $(dig +short A $HOST | head -1):$PORT -servername $HOST 2>/dev/null | grep -q "Verify return code: 0" && echo "TLS OK" || echo "TLS FAILED"

echo -e "\n=== 4. ACME 目录获取测试（关键！）==="
# 强制 IPv4（避开 IPv6 干扰）
curl -4 --max-time 10 -H "Host: $HOST" https://$(dig +short A $HOST | head -1)$PATH 2>/dev/null | grep -q "newNonce" && echo "ACME API OK" || echo "ACME API FAILED"

echo -e "\n=== 5. 总结 ==="
if curl -4 --max-time 10 https://$HOST$PATH -s -o /dev/null; then
  echo "Let's Encrypt 完全可达"
else
  echo "Let's Encrypt 无法连接（建议改用 Buypass）"
fi
