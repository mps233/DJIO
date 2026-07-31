#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
preview_app="${project_root:h}/outputs/DJIO Preview.app"
preview_executable="$preview_app/Contents/MacOS/DJIO"
watch_stamp="$(mktemp -t djio-preview-watch)"

cleanup() {
  /bin/rm -f -- "$watch_stamp"
}
trap cleanup EXIT INT TERM

build_and_launch() {
  touch "$watch_stamp"
  print "\n[$(date '+%H:%M:%S')] 正在更新 DJIO Preview..."

  if ! DJIO_APP_NAME="DJIO Preview" \
    DJIO_BUNDLE_IDENTIFIER="com.local.DJIO.preview" \
    DJIO_BUILD_CONFIGURATION="debug" \
      "$project_root/scripts/build-app.sh"
  then
    print "[$(date '+%H:%M:%S')] 编译失败；修正代码并再次保存后会自动重试。"
    return 1
  fi

  /usr/bin/pkill -f "$preview_executable" 2>/dev/null || true
  /usr/bin/open -n "$preview_app" --args --demo --preview-connection
  print "[$(date '+%H:%M:%S')] 预览已刷新，等待源码变化..."
}

build_and_launch || true

while true; do
  changed_file="$(
    /usr/bin/find \
      "$project_root/Sources" \
      "$project_root/Package.swift" \
      "$project_root/Packaging" \
      -type f -newer "$watch_stamp" -print -quit
  )"

  if [[ -n "$changed_file" ]]; then
    build_and_launch || true
  fi

  sleep 1
done
