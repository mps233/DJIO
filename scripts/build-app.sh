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
asset_info="$project_root/.build/assetcatalog_generated_info.plist"

if [[ -e "$app_path" ]]; then
    /bin/rm -rf -- "$app_path"
fi
/bin/mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/Licenses" "$output_root"

/bin/cp "$binary_path" "$contents/MacOS/CellularBridge"
/bin/cp "$project_root/Packaging/Info.plist" "$contents/Info.plist"
/bin/cp "$libusb_source" "$contents/Frameworks/libusb-1.0.0.dylib"
/bin/cp "$libusb_prefix/COPYING" "$contents/Resources/Licenses/libusb-LGPL-2.1.txt"

/usr/bin/xcrun --sdk macosx actool \
    --compile "$contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$asset_info" \
    --standalone-icon-behavior all \
    --output-format human-readable-text \
    --notices \
    --warnings \
    "$project_root/Packaging/AppIcon.icon"
/usr/libexec/PlistBuddy -c "Merge $asset_info" "$contents/Info.plist"

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
