#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path="${project_root:h}/outputs/DJIO.app"
app_executable="$app_path/Contents/MacOS/DJIO"
installed_executable="/Applications/DJIO.app/Contents/MacOS/DJIO"
legacy_preview_executable="${project_root:h}/outputs/DJIO Preview.app/Contents/MacOS/DJIO"
watch_stamp="$(mktemp -t djio-watch)"

cleanup() {
  /bin/rm -f -- "$watch_stamp"
}
trap cleanup EXIT INT TERM

build_and_launch() {
  touch "$watch_stamp"
  print "\n[$(date '+%H:%M:%S')] 正在更新 DJIO..."

  if ! DJIO_BUILD_CONFIGURATION="debug" \
      "$project_root/scripts/build-app.sh"
  then
    print "[$(date '+%H:%M:%S')] 编译失败；修正代码并再次保存后会自动重试。"
    return 1
  fi

  /usr/bin/pkill -f "$legacy_preview_executable" 2>/dev/null || true
  /usr/bin/pkill -f "$installed_executable" 2>/dev/null || true
  /usr/bin/pkill -f "$app_executable" 2>/dev/null || true
  /usr/bin/open "$app_path"
  print "[$(date '+%H:%M:%S')] DJIO 已刷新，等待源码变化..."
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
