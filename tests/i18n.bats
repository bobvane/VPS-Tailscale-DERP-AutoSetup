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
