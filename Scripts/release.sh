#!/usr/bin/env bash
# release.sh — 빌드 → 서명 → dmg → 공증 → Sparkle 서명 orchestrator.
#
# 사용법:
#   Scripts/release.sh v0.1.0
#
# 환경변수:
#   CC_PM_SIGNING_IDENTITY (필수)
#   CC_PM_NOTARY_PROFILE (필수)
#   CC_PM_BUILD_CONFIG (옵션, 기본 release)
#
# 흐름은 PRD §12.5 배포 파이프라인 참조.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
  echo "사용법: $0 <version-tag>  (예: v0.1.0)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="${REPO_ROOT}/Scripts"
BUILD_DIR="${REPO_ROOT}/.build/release-stage"
APP_NAME="CCPluginManager"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

mkdir -p "${BUILD_DIR}"

echo "════════════════════════════════════════════════════"
echo " Claude Code Plugin Manager — Release ${VERSION}"
echo "════════════════════════════════════════════════════"

# --- 1) Build ---
# TODO: 현재는 SPM 만으로 .app 번들 생성 불가.
# Xcode 프로젝트 또는 xcodegen 도입 후 다음 명령으로 교체:
#   xcodebuild -workspace CCPluginManager.xcworkspace -scheme CCPluginManager \
#              -configuration Release -archivePath "${BUILD_DIR}/App.xcarchive" archive
#   xcodebuild -exportArchive -archivePath "${BUILD_DIR}/App.xcarchive" \
#              -exportOptionsPlist "${SCRIPTS}/exportOptions.plist" -exportPath "${BUILD_DIR}"
echo "❌ TODO: .app 빌드 단계는 Xcode 프로젝트 도입 후 구현."
echo "   현재는 SPM 개발 빌드만 가능: cd Packages/App && swift run CCPluginManager"
exit 2

# --- 2) Sign ---
"${SCRIPTS}/sign.sh" "${APP_PATH}"

# --- 3) DMG ---
"${SCRIPTS}/build-dmg.sh" "${APP_PATH}" "${DMG_PATH}"

# --- 4) Notarize + Staple ---
"${SCRIPTS}/notarize.sh" "${DMG_PATH}"

# --- 5) Sparkle 서명 (sign_update 가 EdDSA 시그니처 출력) ---
SIGN_UPDATE="${SIGN_UPDATE:-/Applications/Sparkle.app/Contents/MacOS/sign_update}"
if [[ -x "${SIGN_UPDATE}" ]]; then
  echo "🔏 Sparkle EdDSA 서명..."
  ED_SIG=$("${SIGN_UPDATE}" "${DMG_PATH}")
  echo "   appcast.xml 의 enclosure 에 추가: ${ED_SIG}"
fi

echo "✅ Release ${VERSION} 빌드 + 서명 + 공증 완료: ${DMG_PATH}"
echo "   다음 단계 (수동):"
echo "     1) gh release create ${VERSION} ${DMG_PATH}"
echo "     2) appcast.xml 갱신 + 푸시"
echo "     3) Homebrew Tap 의 ccplugin.rb 의 version + sha256 갱신 PR"
