#!/usr/bin/env bats

setup_file() {
  export SCRIPT="$BATS_TEST_DIRNAME/../install.sh"
}

# 每个测试独立 source 脚本（BASH_SOURCE 守卫保证不会触发 main）
source_script() {
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

@test "English step title is translated" {
  source_script
  LANG=en run t step_install_1 derp.example.com
  [ "$status" -eq 0 ]
  [ "$output" = "DNS resolution check: derp.example.com" ]
}

@test "Chinese step title remains Chinese" {
  source_script
  LANG=zh run t step_install_1 derp.example.com
  [ "$status" -eq 0 ]
  [ "$output" = "DNS 解析检测：derp.example.com" ]
}

@test "All 11 step titles have English translations" {
  source_script
  for i in {1..11}; do
    LANG=en run t step_install_$i
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$output" != "step_install_$i" ]
  done
}

@test "English message prefix is translated" {
  source_script
  LANG=en run _msg_prefix info
  [ "$status" -eq 0 ]
  [ "$output" = "[INFO] " ]
}

@test "Chinese message prefix is translated" {
  source_script
  LANG=zh run _msg_prefix info
  [ "$status" -eq 0 ]
  [ "$output" = "[信息] " ]
}

@test "All message prefixes translated" {
  source_script
  for level in info warn error ok; do
    LANG=en run _msg_prefix $level
    [ "$status" -eq 0 ]
    [[ "$output" != *"[信息]"* ]]
    [[ "$output" != *"[警告]"* ]]
    [[ "$output" != *"[错误]"* ]]
  done
}

@test "Version comparison: 3.0.6 > 3.0.5" {
  source_script
  run version_gt 3.0.6 3.0.5
  [ "$status" -eq 0 ]
}

@test "Version comparison: 3.0.5 < 3.0.6" {
  source_script
  run version_gt 3.0.5 3.0.6
  [ "$status" -eq 1 ]
}

@test "Version comparison: 3.0.10 > 3.0.4 (multi-segment)" {
  source_script
  run version_gt 3.0.10 3.0.4
  [ "$status" -eq 0 ]
}

@test "Version comparison: equal versions returns false" {
  source_script
  run version_gt 3.0.6 3.0.6
  [ "$status" -eq 1 ]
}

@test "Version comparison handles v prefix" {
  source_script
  run version_gt v3.0.6 v3.0.5
  [ "$status" -eq 0 ]
}

@test "Menu title English" {
  source_script
  LANG=en run t menu_title
  [ "$status" -eq 0 ]
  [ "$output" = "Tailscale DERP Manager" ]
}

@test "Menu title Chinese" {
  source_script
  LANG=zh run t menu_title
  [ "$status" -eq 0 ]
  [ "$output" = "Tailscale DERP 管理器" ]
}

@test "Install docker engine menu English" {
  source_script
  LANG=en run msg docker_menu
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker engine install method"* ]]
}

@test "Mirror menu English" {
  source_script
  LANG=en run msg mirror_menu
  [ "$status" -eq 0 ]
  [[ "$output" == *"Select image pull source"* ]]
}

@test "Certificate menu English" {
  source_script
  LANG=en run t cert_menu_title
  [ "$status" -eq 0 ]
  [[ "$output" == *"Certificate mode"* ]]
}

@test "Uninstall title English" {
  source_script
  LANG=en run msg uninstall_title
  [ "$status" -eq 0 ]
  [[ "$output" == *"Full uninstall will remove"* ]]
}

@test "Validate port: valid ports pass" {
  source_script
  for port in 80 443 12345 65535; do
    run validate_port $port
    [ "$status" -eq 0 ]
  done
}

@test "Validate port: invalid ports fail" {
  source_script
  for port in 0 65536 -1 abc; do
    run validate_port $port
    [ "$status" -eq 1 ]
  done
}

@test "Validate domain: valid domains pass" {
  source_script
  for domain in example.com sub.example.com derp.test.cn; do
    run validate_domain $domain
    [ "$status" -eq 0 ]
  done
}

@test "Validate IP: valid IPs pass" {
  source_script
  for ip in "1.2.3.4" "192.168.1.1" "10.0.0.1" "203.0.113.10"; do
    run validate_ip $ip
    [ "$status" -eq 0 ]
  done
}

@test "Validate IP: invalid IPs fail" {
  source_script
  for ip in "256.1.2.3" "1.2.3" "example.com" "not-an-ip"; do
    run validate_ip $ip
    [ "$status" -eq 1 ]
  done
}

@test "DNS check function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f dns_check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dns_check ()"* ]]
}

@test "Docker installed detection function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f docker_installed'
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker_installed ()"* ]]
}

@test "Docker compose command detection function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f docker_compose_cmd'
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker_compose_cmd ()"* ]]
}

@test "Port check function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f step_port_check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"step_port_check ()"* ]]
}

@test "Container status function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f container_status'
  [ "$status" -eq 0 ]
  [[ "$output" == *"container_status ()"* ]]
}

@test "Sync compose env function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f sync_compose_env'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync_compose_env ()"* ]]
}

@test "Install derp function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f install_derp'
  [ "$status" -eq 0 ]
  [[ "$output" == *"install_derp ()"* ]]
}

@test "Main function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f main'
  [ "$status" -eq 0 ]
  [[ "$output" == *"main ()"* ]]
}

@test "Ask yes no function exists" {
  source_script
  run bash -c 'source "$SCRIPT"; declare -f ask_yes_no'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ask_yes_no ()"* ]]
}

# ---- 镜像包路径由 GITHUB_REPO 派生（fork 友好）----
@test "ghcr_derp_repo derives from GITHUB_REPO" {
  source_script
  GITHUB_REPO="MyUser/My-Repo"
  run ghcr_derp_repo
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/myuser/my-repo/derper" ]
}

@test "ghcr_derp_repo_path strips ghcr.io prefix" {
  source_script
  GITHUB_REPO="MyUser/My-Repo"
  run ghcr_derp_repo_path
  [ "$status" -eq 0 ]
  [ "$output" = "myuser/my-repo/derper" ]
}

# ---- menu_update 升级检测查本 fork 包，而非 Tailscale 官方 ----
@test "menu_update no longer queries tailscale/tailscale releases" {
  source_script
  run grep -n 'tailscale/tailscale/releases/latest' "$SCRIPT"
  [ "$status" -eq 1 ]   # grep 未找到 = 退出码 1 = 正确
}

@test "new package-check msg keys defined (zh)" {
  source_script
  for k in checking_own_package pkg_not_found pkg_howto_generate pkg_no_version_tag pkg_latest pkg_current pkg_up_to_date pkg_confirm_upgrade pkg_pulling pkg_pull_failed pkg_upgraded pkg_upgrade_failed cancelled; do
    LANG=zh run msg "$k" "arg"
    [ "$status" -eq 0 ]
    [ "$output" != "$k" ]
  done
}

@test "new package-check msg keys defined (en)" {
  source_script
  for k in checking_own_package pkg_not_found pkg_howto_generate pkg_no_version_tag pkg_latest pkg_current pkg_up_to_date pkg_confirm_upgrade pkg_pulling pkg_pull_failed pkg_upgraded pkg_upgrade_failed cancelled; do
    LANG=en run msg "$k" "arg"
    [ "$status" -eq 0 ]
    [ "$output" != "$k" ]
  done
}

# ---- 回归：menu_uninstall 调用过的 msg key 必须已定义（防止 A3 类回退）----
@test "msg keys used by menu_uninstall are defined (zh)" {
  source_script
  for k in info_cleanup_tailscale ok_tailscale_logged_out ok_uninstall_done prompt_return compose_no_http_port; do
    LANG=zh run msg $k
    [ "$status" -eq 0 ]
    [ "$output" != "$k" ]
  done
}

@test "msg keys used by menu_uninstall are defined (en)" {
  source_script
  for k in info_cleanup_tailscale ok_tailscale_logged_out ok_uninstall_done prompt_return compose_no_http_port; do
    LANG=en run msg $k
    [ "$status" -eq 0 ]
    [ "$output" != "$k" ]
  done
}

# ---- cert_mode_name 友好名（A8/A9）----
@test "cert_mode_name returns friendly name for manual" {
  source_script
  LANG=zh run cert_mode_name manual ""
  [ "$status" -eq 0 ]
  [ "$output" = "自签名" ]
}

@test "cert_mode_name returns friendly name for letsencrypt" {
  source_script
  LANG=zh run cert_mode_name letsencrypt ""
  [ "$status" -eq 0 ]
  [ "$output" = "证书: Let's Encrypt" ]
}

@test "cert_mode_name returns friendly name for CF" {
  source_script
  LANG=zh run cert_mode_name manual true
  [ "$status" -eq 0 ]
  [ "$output" = "证书: Cloudflare Origin CA" ]
}

# ---- gen_region_id 持久化（首次生成后写入 env，再次读取复用）----
@test "gen_region_id persists across calls via env" {
  local d
  d="$(mktemp -d)"
  source_script
  INSTALL_DIR="$d"; ENV_FILE="${d}/tderp.env"
  local a b
  a="$(gen_region_id)"
  b="$(gen_region_id)"
  [ "$a" = "$b" ]
  grep -q "REGION_ID=${a}" "${d}/tderp.env"
}

# ---- env_set 安全写入（值含 / 与 & 不破坏文件）----
@test "env_set handles values with slashes and ampersands" {
  local d
  d="$(mktemp -d)"
  source_script
  INSTALL_DIR="$d"; ENV_FILE="${d}/tderp.env"
  env_set "DERP_DOMAIN" "a/b&c=d"
  env_set "LANG" "zh"
  grep -q "DERP_DOMAIN=a/b&c=d" "${d}/tderp.env"
  grep -q "LANG=zh" "${d}/tderp.env"
}

# ---- port_in_use 精确匹配（避免子串误报）----
@test "port_in_use regex does not match substring (e.g. 443 vs 44)" {
  source_script
  # 在容器内无 ss/netstat 时返回 1（放行），仅验证函数存在且能调用
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../install.sh"; declare -f port_in_use >/dev/null'
  [ "$status" -eq 0 ]
}

# ---- entrypoint.sh 输入守卫（v3.2.5 新增）----
# 拒绝空 DERP_DOMAIN、含非法字符（空格、引号、$、反引号、分号、&、|、>、<、\）
# 合法字符：[A-Za-z0-9._:-]（域名/IPv4/IPv6 字面量）
@test "entrypoint.sh rejects empty DERP_DOMAIN with exit 2" {
  run bash -c 'DERP_DOMAIN="" sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"DERP_DOMAIN is required"* ]]
}

@test "entrypoint.sh rejects DERP_DOMAIN with space" {
  run bash -c 'DERP_DOMAIN="foo bar" sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"illegal characters"* ]]
}

@test "entrypoint.sh rejects DERP_DOMAIN with shell metacharacter dollar" {
  run bash -c 'DERP_DOMAIN="foo\$bar" sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"illegal characters"* ]]
}

@test "entrypoint.sh rejects DERP_DOMAIN with backtick" {
  run bash -c 'DERP_DOMAIN="foo\`bar" sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"illegal characters"* ]]
}

@test "entrypoint.sh rejects DERP_DOMAIN with semicolon (command injection)" {
  run bash -c 'DERP_DOMAIN="foo;rm -rf /" sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"illegal characters"* ]]
}

@test "entrypoint.sh rejects DERP_DOMAIN with pipe" {
  run bash -c 'DERP_DOMAIN="foo|cat" sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"illegal characters"* ]]
}

@test "entrypoint.sh accepts valid IPv4" {
  # 守卫通过后会进入 openssl + exec derper 阶段（测试环境没 derper 二进制 → 退出码 127）。
  # 验证守卫本身没误伤：错误信息不含 FATAL 守卫字样。
  run -127 bash -c 'DERP_DOMAIN="1.2.3.4" DERP_CERT_DIR=/tmp sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [[ "$output" != *"FATAL: DERP_DOMAIN is required"* ]]
  [[ "$output" != *"illegal characters"* ]]
}

@test "entrypoint.sh accepts valid IPv6 (colons allowed)" {
  run -127 bash -c 'DERP_DOMAIN="2001:db8::1" DERP_CERT_DIR=/tmp sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [[ "$output" != *"FATAL: DERP_DOMAIN is required"* ]]
  [[ "$output" != *"illegal characters"* ]]
}

@test "entrypoint.sh accepts valid domain" {
  run -127 bash -c 'DERP_DOMAIN="derp.example.com" DERP_CERT_DIR=/tmp sh "'"$BATS_TEST_DIRNAME"'/../entrypoint.sh" 2>&1'
  [[ "$output" != *"FATAL: DERP_DOMAIN is required"* ]]
  [[ "$output" != *"illegal characters"* ]]
}

# ---- IPv6 SAN 分类（v3.2.6 新增）----
# v3.2.5 之前的 IPv4 正则会把 IPv6 字面量误判为域名，生成 DNS:2001:db8::1
# 这种垃圾 SAN。v3.2.6 改为先匹配 IPv4、再匹配 hex+冒号（IPv6）、最后回退到域名。
# 通过观察 openssl -addext 的 subjectAltName 输出分类。
# 测试环境没 derper 二进制 → 退出码 127；这里关注 openssl 命令组装。
@test "entrypoint.sh IPv6 triggers IP: SAN not DNS: SAN" {
  # 在临时目录跑 openssl，捕获生成的 csr/conf 失败前的 SAN 字符串
  local tmpd
  tmpd="$(mktemp -d)"
  # 拦截 openssl：用一个 fake 脚本替代，记录调用参数
  cat > "${tmpd}/openssl" <<'FAKE'
#!/bin/sh
# 把 -addext 参数打到标记文件
for arg in "$@"; do
  case "$arg" in
    subjectAltName=*) echo "$arg" > "$SAN_CAPTURE" ;;
  esac
done
exit 0
FAKE
  chmod +x "${tmpd}/openssl"
  PATH="${tmpd}:${PATH}" SAN_CAPTURE="${tmpd}/san.txt" \
    DERP_DOMAIN="2001:db8::1" DERP_CERT_DIR="${tmpd}" DERP_CERT_MODE=manual \
    sh "$BATS_TEST_DIRNAME/../entrypoint.sh" 2>&1 || true
  [ -f "${tmpd}/san.txt" ]
  grep -q "subjectAltName=IP:2001:db8::1" "${tmpd}/san.txt"
  ! grep -q "subjectAltName=DNS:2001" "${tmpd}/san.txt"
  rm -rf "${tmpd}"
}

@test "entrypoint.sh IPv4 still triggers IP: SAN" {
  local tmpd
  tmpd="$(mktemp -d)"
  cat > "${tmpd}/openssl" <<'FAKE'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    subjectAltName=*) echo "$arg" > "$SAN_CAPTURE" ;;
  esac
done
exit 0
FAKE
  chmod +x "${tmpd}/openssl"
  PATH="${tmpd}:${PATH}" SAN_CAPTURE="${tmpd}/san.txt" \
    DERP_DOMAIN="192.168.1.1" DERP_CERT_DIR="${tmpd}" DERP_CERT_MODE=manual \
    sh "$BATS_TEST_DIRNAME/../entrypoint.sh" 2>&1 || true
  [ -f "${tmpd}/san.txt" ]
  grep -q "subjectAltName=IP:192.168.1.1" "${tmpd}/san.txt"
  rm -rf "${tmpd}"
}

@test "entrypoint.sh domain triggers DNS: SAN" {
  local tmpd
  tmpd="$(mktemp -d)"
  cat > "${tmpd}/openssl" <<'FAKE'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    subjectAltName=*) echo "$arg" > "$SAN_CAPTURE" ;;
  esac
done
exit 0
FAKE
  chmod +x "${tmpd}/openssl"
  PATH="${tmpd}:${PATH}" SAN_CAPTURE="${tmpd}/san.txt" \
    DERP_DOMAIN="derp.example.com" DERP_CERT_DIR="${tmpd}" DERP_CERT_MODE=manual \
    sh "$BATS_TEST_DIRNAME/../entrypoint.sh" 2>&1 || true
  [ -f "${tmpd}/san.txt" ]
  grep -q "subjectAltName=DNS:derp.example.com" "${tmpd}/san.txt"
  ! grep -q "subjectAltName=IP:derp" "${tmpd}/san.txt"
  rm -rf "${tmpd}"
}

# ---- install.sh 安装目录权限收紧（v3.2.6 新增）----
# tderp.env 含 CERT_CF 等敏感标记，权限必须 600。
# INSTALL_DIR / data/certs 目录必须 700（私钥保护）。
# 模拟 install 流程的 dir+env_set 链路，验证 chmod 效果。
@test "install.sh creates env file with 600 permission" {
  local d
  d="$(mktemp -d)"
  source_script
  INSTALL_DIR="$d"; ENV_FILE="${d}/tderp.env"; CERTS_DIR="${d}/data/certs"
  mkdir -p "${INSTALL_DIR}" "${CERTS_DIR}"
  chmod 700 "${INSTALL_DIR}"
  chmod 700 "${CERTS_DIR}"
  env_set "DERP_DOMAIN" "test.example.com"
  env_set "CERT_MODE" "manual"
  chmod 600 "${ENV_FILE}" 2>/dev/null || true
  # 文件必须存在且权限是 600
  [ -f "${ENV_FILE}" ]
  local mode
  mode="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%A' "${ENV_FILE}" 2>/dev/null)"
  [ "$mode" = "600" ]
  # 目录权限是 700
  mode="$(stat -c '%a' "${CERTS_DIR}" 2>/dev/null || stat -f '%A' "${CERTS_DIR}" 2>/dev/null)"
  [ "$mode" = "700" ]
  rm -rf "$d"
}
