#!/usr/bin/env bats

setup_file() {
  export SCRIPT="$BATS_TEST_DIRNAME/../install.sh"
}

@test "English step title is translated" {
  run bash -c 'LANG=en; source "$1"; t step_install_1 derp.example.com' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "DNS resolution check: derp.example.com" ]
}

@test "Chinese step title remains Chinese" {
  run bash -c 'LANG=zh; source "$1"; t step_install_1 derp.example.com' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "DNS 解析检测：derp.example.com" ]
}

@test "All 11 step titles have English translations" {
  for i in {1..11}; do
    run bash -c "LANG=en; source \"\$1\"; t step_install_\$i" _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != "step_install_$i" ]]
  done
}

@test "English message prefix is translated" {
  run bash -c 'LANG=en; source "$1"; _msg_prefix info' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "[INFO] " ]
}

@test "Chinese message prefix is translated" {
  run bash -c 'LANG=zh; source "$1"; _msg_prefix info' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "[信息] " ]
}

@test "All message prefixes translated" {
  for level in info warn error ok; do
    run bash -c "LANG=en; source \"\$1\"; _msg_prefix \$level" _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"[信息]"* ]]
    [[ "$output" != *"[警告]"* ]]
    [[ "$output" != *"[错误]"* ]]
    [[ "$output" != *"[信息]"* ]]
  done
}

@test "Version comparison: 3.0.6 > 3.0.5" {
  run bash -c 'source "$1"; version_gt 3.0.6 3.0.5' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Version comparison: 3.0.5 < 3.0.6" {
  run bash -c 'source "$1"; version_gt 3.0.5 3.0.6' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "Version comparison: 3.0.10 > 3.0.4 (multi-segment)" {
  run bash -c 'source "$1"; version_gt 3.0.10 3.0.4' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Version comparison: equal versions returns false" {
  run bash -c 'source "$1"; version_gt 3.0.6 3.0.6' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "Version comparison handles v prefix" {
  run bash -c 'source "$1"; version_gt v3.0.6 v3.0.5' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Menu title English" {
  run bash -c 'LANG=en; source "$1"; t menu_title' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "Tailscale DERP Manager" ]
}

@test "Menu title Chinese" {
  run bash -c 'LANG=zh; source "$1"; t menu_title' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "Tailscale DERP 管理器" ]
}

@test "Install docker engine menu English" {
  run bash -c 'LANG=en; source "$1"; msg docker_menu' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker engine install method"* ]]
}

@test "Mirror menu English" {
  run bash -c 'LANG=en; source "$1"; msg mirror_menu' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Select image pull source"* ]]
}

@test "Certificate menu English" {
  run bash -c 'LANG=en; source "$1"; msg cert_menu_title' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Certificate mode"* ]]
}

@test "Uninstall title English" {
  run bash -c 'LANG=en; source "$1"; msg uninstall_title' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Full uninstall will remove"* ]]
}

@test "Validate port: valid ports pass" {
  for port in 80 443 12345 65535; do
    run bash -c "source \"\$1\"; validate_port $port" _ "$SCRIPT"
    [ "$status" -eq 0 ]
  done
}

@test "Validate port: invalid ports fail" {
  for port in 0 65536 -1 abc; do
    run bash -c "source \"\$1\"; validate_port $port" _ "$SCRIPT"
    [ "$status" -eq 1 ]
  done
}

@test "Validate domain: valid domains pass" {
  for domain in example.com sub.example.com derp.test.cn; do
    run bash -c "source \"\$1\"; validate_domain $domain" _ "$SCRIPT"
    [ "$status" -eq 0 ]
  done
}

@test "Validate IP: valid IPs pass" {
  for ip in "1.2.3.4" "192.168.1.1" "10.0.0.1" "203.0.113.10"; do
    run bash -c "source \"\$1\"; validate_ip $ip" _ "$SCRIPT"
    [ "$status" -eq 0 ]
  done
}

@test "Validate IP: invalid IPs fail" {
  for ip in "256.1.2.3" "1.2.3" "example.com" "not-an-ip"; do
    run bash -c "source \"\$1\"; validate_ip $ip" _ "$SCRIPT"
    [ "$status" -eq 1 ]
  done
}

@test "DNS check function exists" {
  run bash -c 'source "$1"; declare -f dns_check' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dns_check ()"* ]]
}

@test "Docker installed detection function exists" {
  run bash -c 'source "$1"; declare -f docker_installed' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker_installed ()"* ]]
}

@test "Docker compose command detection function exists" {
  run bash -c 'source "$1"; declare -f docker_compose_cmd' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker_compose_cmd ()"* ]]
}

@test "Port check function exists" {
  run bash -c 'source "$1"; declare -f step_port_check' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"step_port_check ()"* ]]
}

@test "Container status function exists" {
  run bash -c 'source "$1"; declare -f container_status' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"container_status ()"* ]]
}

@test "Sync compose env function exists" {
  run bash -c 'source "$1"; declare -f sync_compose_env' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync_compose_env ()"* ]]
}

@test "Install derp function exists" {
  run bash -c 'source "$1"; declare -f install_derp' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"install_derp ()"* ]]
}

@test "Main function exists" {
  run bash -c 'source "$1"; declare -f main' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main ()"* ]]
}

@test "Ask yes no function exists" {
  run bash -c 'source "$1"; declare -f ask_yes_no' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ask_yes_no ()"* ]]