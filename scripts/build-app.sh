#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
output_root="${project_root:h}/outputs"
app_name="${DJIO_APP_NAME:-DJIO}"
build_configuration="${DJIO_BUILD_CONFIGURATION:-release}"
app_path="$output_root/$app_name.app"
contents="$app_path/Contents"
swift build --package-path "$project_root" -c "$build_configuration"
binary_path="$(
  swift build --package-path "$project_root" -c "$build_configuration" --show-bin-path
)/DJIO"
libusb_prefix="$(brew --prefix libusb)"
libusb_source="$libusb_prefix/lib/libusb-1.0.0.dylib"
asset_info="$project_root/.build/assetcatalog_generated_info.plist"
lpac_source="$project_root/Packaging/Helpers/lpac/lpac"
lpac_expected_sha256="f026d231108f66d395e27d650a0d2df96e796d3ca4484b15efe293d20cea37dc"

lpac_actual_sha256="$(/usr/bin/shasum -a 256 "$lpac_source" | /usr/bin/awk '{print $1}')"
if [[ "$lpac_actual_sha256" != "$lpac_expected_sha256" ]]; then
    echo "lpac helper 校验失败：$lpac_actual_sha256" >&2
    exit 1
fi
"$project_root/scripts/test-lpac-helper.sh"

if [[ -e "$app_path" ]]; then
    /bin/rm -rf -- "$app_path"
fi
/bin/mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Helpers" "$contents/Resources/Licenses" "$output_root"

/bin/cp "$binary_path" "$contents/MacOS/DJIO"
/bin/cp "$project_root/Packaging/Info.plist" "$contents/Info.plist"
if [[ -n "${DJIO_BUNDLE_IDENTIFIER:-}" ]]; then
    /usr/libexec/PlistBuddy \
      -c "Set :CFBundleIdentifier $DJIO_BUNDLE_IDENTIFIER" \
      "$contents/Info.plist"
fi
if [[ "$app_name" != "DJIO" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$contents/Info.plist"
fi
/bin/cp "$libusb_source" "$contents/Frameworks/libusb-1.0.0.dylib"
/bin/cp "$libusb_prefix/COPYING" "$contents/Resources/Licenses/libusb-LGPL-2.1.txt"
/bin/cp "$lpac_source" "$contents/Helpers/lpac"
/bin/chmod 755 "$contents/Helpers/lpac"
/bin/cp "$project_root/Packaging/Helpers/lpac/LICENSE-lpac" "$contents/Resources/Licenses/lpac-AGPL-3.0.txt"
/bin/cp "$project_root/Packaging/Helpers/lpac/LICENSE-libeuicc" "$contents/Resources/Licenses/libeuicc-LGPL-2.1.txt"
/bin/cp "$project_root/Packaging/Helpers/lpac/LICENSE-cjson" "$contents/Resources/Licenses/cjson-MIT.txt"
/bin/cp "$project_root/Packaging/Helpers/lpac/SOURCE.txt" "$contents/Resources/Licenses/lpac-SOURCE.txt"
/bin/cp "$project_root/Packaging/Helpers/lpac/patches/0001-djio-stdio-and-secret-input.patch" "$contents/Resources/Licenses/lpac-DJIO.patch"

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

dependency="$(/usr/bin/otool -L "$contents/MacOS/DJIO" | /usr/bin/awk '/libusb-1.0/{print $1; exit}')"
if [[ -n "$dependency" ]]; then
    /usr/bin/install_name_tool -change "$dependency" "@rpath/libusb-1.0.0.dylib" "$contents/MacOS/DJIO"
fi
/usr/bin/install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$contents/Frameworks/libusb-1.0.0.dylib"
if ! /usr/bin/otool -l "$contents/MacOS/DJIO" | /usr/bin/grep -q '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents/MacOS/DJIO"
fi

/usr/bin/plutil -lint "$contents/Info.plist"
bundle_identifier="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$contents/Info.plist")"
designated_requirement="=designated => identifier \"$bundle_identifier\""
/usr/bin/codesign --force --sign - "$contents/Frameworks/libusb-1.0.0.dylib"
/usr/bin/codesign --force --sign - "$contents/Helpers/lpac"
/usr/bin/codesign \
    --force \
    --sign - \
    --requirements "$designated_requirement" \
    "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo "$app_path"
