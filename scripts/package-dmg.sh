#!/bin/bash
# Package the built app for drag-and-drop replacement in Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="build/Notchline.app.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto -x -k "$ZIP" "$STAGE"
APP="$STAGE/Notchline.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "local.notchline.personal"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist")" = "Notchline"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" = "Notchline"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
DMG="build/Notchline-$VERSION.dmg"
if test -e "$DMG"; then
  echo "Already packaged $DMG. Increase the release version before shipping another upgrade." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<INSTRUCTIONS
Notchline $VERSION

1. 在菜单栏退出旧版 Notchline。
2. 把 Notchline.app 拖入旧版所在的文件夹，选择“替换”。首次安装可拖到 Applications。
3. 首次启动后，复制的图片和文字会自动挂上。可在菜单栏分别关闭收集，或在“新纸签样式”中选择“随机彩纸”或“经典米色”。
4. 在 Notchline 菜单栏进入“双击粘贴权限”→“打开权限设置…”，允许当前安装的 Notchline。如果已开启但应用仍显示需要授权，移除列表中旧的 Notchline，再添加原安装目录里的 Notchline.app。可用“在访达中显示此应用”找到它。
5. 点入目标输入框，再双击文字或图片即可粘贴。在“外观主题”中可切换“晾衣绳”与“粒子浮现”，内容和操作方式保持一致。

粒子主题中，卡片底边在透光槽内对齐；将卡片下沿拖回槽口即可归位。

原有设置和已挂内容保存在用户资料目录中。

此安装包采用本地签名。首次打开若被 macOS 拦截，请先尝试打开一次，
随后到“系统设置”→“隐私与安全性”点按“仍要打开”，再次确认打开。

English

Quit the previous Notchline. Drag Notchline.app into the folder containing
the previous version and choose Replace. For a first install, use Applications.
On a fresh install, copied images and text hang automatically, and new text
clippings use random paper colors. In the menu bar you can turn off either
clipboard option or choose New clipping style > Classic cream.
Use Double-click paste access > Open permission settings to allow the installed
Notchline. If the switch is on but the menu reports missing access after an
upgrade, remove only the old Notchline entry and add the current copy again.
Show this app in Finder locates it. Then focus an editor and double-click to paste.
Appearance switches between Clothesline and Particle emergence; saved items and
gestures are shared between both themes. In Particle emergence, return a card
by bringing its lower edge back to the translucent shelf slot.
If macOS blocks the first launch, try opening it once, then use
System Settings > Privacy & Security > Open Anyway.
INSTRUCTIONS

# HFS+ also mounts on every supported macOS release. Explicitly selecting it
# avoids the host's APFS formatter, which can hang while creating a small image.
hdiutil create -volname "Notchline $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
echo "Built $DMG"
