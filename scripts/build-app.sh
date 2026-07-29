#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
output_root="${project_root:h}/outputs"
app_path="$output_root/CellularBridge.app"
contents="$app_path/Contents"
swift build --package-path "$project_root" -c release
binary_path="$(swift build --package-path "$project_root" -c release --show-bin-path)/CellularBridge"
libusb_prefix="$(brew --prefix libusb)"
libusb_source="$libusb_prefix/lib/libusb-1.0.0.dylib"
iconset="$project_root/.build/AppIcon.iconset"

if [[ -e "$app_path" ]]; then
    /bin/rm -rf -- "$app_path"
fi
/bin/mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/Licenses" "$output_root"

/usr/bin/swift "$project_root/scripts/generate-icon.swift" "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"

/bin/cp "$binary_path" "$contents/MacOS/CellularBridge"
/bin/cp "$project_root/Packaging/Info.plist" "$contents/Info.plist"
/bin/cp "$libusb_source" "$contents/Frameworks/libusb-1.0.0.dylib"
/bin/cp "$libusb_prefix/COPYING" "$contents/Resources/Licenses/libusb-LGPL-2.1.txt"

dependency="$(/usr/bin/otool -L "$contents/MacOS/CellularBridge" | /usr/bin/awk '/libusb-1.0/{print $1; exit}')"
if [[ -n "$dependency" ]]; then
    /usr/bin/install_name_tool -change "$dependency" "@rpath/libusb-1.0.0.dylib" "$contents/MacOS/CellularBridge"
fi
/usr/bin/install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$contents/Frameworks/libusb-1.0.0.dylib"
if ! /usr/bin/otool -l "$contents/MacOS/CellularBridge" | /usr/bin/grep -q '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents/MacOS/CellularBridge"
fi

/usr/bin/plutil -lint "$contents/Info.plist"
/usr/bin/codesign --force --sign - "$contents/Frameworks/libusb-1.0.0.dylib"
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo "$app_path"
