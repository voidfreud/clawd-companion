#!/bin/zsh
# Builds native/build/Desk Clawd.app from main.swift and ../desk-clawd.html.
#   ./build.sh            build only
#   ./build.sh --install  build, then replace /Applications/Desk Clawd.app and relaunch it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Desk Clawd.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O main.swift -o "$APP/Contents/MacOS/DeskClawd" -framework Cocoa -framework WebKit -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"

# The artifact page is written without a document skeleton (claude.ai adds one); add it here.
# The native app makes no network requests: drop the web-font links and let the system font stand in.
{
  print -r -- '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}</style></head><body>'
  grep -v -e 'fonts.googleapis.com' -e 'fonts.gstatic.com' ../desk-clawd.html
  print -r -- '</body></html>'
} > "$APP/Contents/Resources/clawd.html"

# Sign with the first Apple Development identity if there is one, otherwise ad hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/Desk Clawd.app"
  osascript -e 'quit app id "local.deskclawd"' 2>/dev/null || true
  for _ in {1..20}; do pgrep -qf "$DEST/Contents/MacOS/DeskClawd" || break; sleep 0.25; done
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
