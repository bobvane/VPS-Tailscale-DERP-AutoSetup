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
