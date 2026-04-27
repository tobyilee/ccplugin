#!/usr/bin/env bash
# install-local.sh — 로컬 release 빌드 → .app 번들 → /Applications 설치 + 로그인 항목 등록.
#
# 배포용이 아니라 본인 머신에 빠르게 설치하는 dev 경로.
# Apple Developer 인증서 불필요 (ad-hoc codesign).
# 배포는 sign.sh + notarize.sh + build-dmg.sh 사용.
#
# 사용법:
#   Scripts/install-local.sh             # build + install + 로그인 항목 묻기
#   Scripts/install-local.sh --no-login  # 로그인 항목 등록 생략
#   Scripts/install-local.sh --uninstall # /Applications 에서 제거 + 로그인 항목 해제

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PKG_DIR="${ROOT}/Packages/App"
APP_NAME="CCPluginManager"
DISPLAY_NAME="Claude Code Plugin Manager"
BUNDLE_ID="com.tobyilee.ccpluginmanager"
APP_VERSION="0.1.0"   # AppInfo.version (AppMain.swift) 와 sync — 둘 다 같이 bump.
INSTALL_DIR="/Applications"
INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}.app"

uninstall() {
  echo "🗑  로그인 항목 해제..."
  osascript -e "tell application \"System Events\" to delete login item \"${APP_NAME}\"" 2>/dev/null \
    || echo "   (등록되어 있지 않음)"

  if [[ -d "${INSTALLED_APP}" ]]; then
    echo "🗑  ${INSTALLED_APP} 제거..."
    rm -rf "${INSTALLED_APP}"
  else
    echo "   (이미 설치되어 있지 않음)"
  fi
  echo "✅ 제거 완료."
  exit 0
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall
fi

REGISTER_LOGIN=1
if [[ "${1:-}" == "--no-login" ]]; then
  REGISTER_LOGIN=0
fi

# 1) Release 빌드.
echo "🔨 Release 빌드 (Packages/App)..."
( cd "${APP_PKG_DIR}" && swift build -c release )
BIN="${APP_PKG_DIR}/.build/release/${APP_NAME}"
if [[ ! -x "${BIN}" ]]; then
  echo "❌ 빌드 산출물 없음: ${BIN}" >&2
  exit 1
fi

# 2) .app 번들 조립 (임시 staging 디렉토리).
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
APP_BUNDLE="${STAGE}/${APP_NAME}.app"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                  <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>                  <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>       <string>6.0</string>
    <key>CFBundleName</key>                        <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>                 <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>                 <string>APPL</string>
    <key>CFBundleShortVersionString</key>          <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>                     <string>${APP_VERSION}</string>
    <key>LSMinimumSystemVersion</key>              <string>13.0</string>
    <key>LSUIElement</key>                         <true/>
    <key>NSHighResolutionCapable</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>       <string>System Events 통한 login item 등록.</string>
</dict>
</plist>
PLIST

# 3) Ad-hoc codesign — Gatekeeper 1차 통과 (배포용 X, 본인 머신 OK).
echo "🔐 ad-hoc codesign..."
codesign --force --sign - --options runtime --timestamp=none "${APP_BUNDLE}" 2>&1 \
  | sed 's/^/   /'

# 4) /Applications 로 설치 (이전 버전 덮어쓰기).
if [[ -d "${INSTALLED_APP}" ]]; then
  echo "♻️  기존 ${INSTALLED_APP} 덮어쓰기..."
  rm -rf "${INSTALLED_APP}"
fi
echo "📦 설치: ${INSTALLED_APP}"
cp -R "${APP_BUNDLE}" "${INSTALLED_APP}"
xattr -dr com.apple.quarantine "${INSTALLED_APP}" 2>/dev/null || true

# 5) 로그인 항목 등록 (osascript → System Events).
if [[ "${REGISTER_LOGIN}" == "1" ]]; then
  echo "🔑 로그인 항목 등록 (System Events)..."
  # 이미 있으면 일단 제거 후 재등록 — 항상 최신 path 가리키도록.
  osascript -e "tell application \"System Events\" to delete login item \"${APP_NAME}\"" 2>/dev/null || true
  osascript <<APPLESCRIPT
tell application "System Events"
    make login item at end with properties {path:"${INSTALLED_APP}", hidden:true, name:"${APP_NAME}"}
end tell
APPLESCRIPT
  echo "   ✅ 다음 부팅부터 자동 실행됨."
  echo "      (System Settings → General → Login Items 에서 확인/해제 가능)"
else
  echo "ℹ️  --no-login 지정 — 로그인 항목 등록 생략."
fi

# 6) 지금 한 번 띄워보기.
echo ""
echo "🚀 지금 실행: open \"${INSTALLED_APP}\""
echo "✅ 완료."
