#!/usr/bin/env bash
# sign.sh — Developer ID Application 서명 + Hardened Runtime.
#
# 사용법:
#   CC_PM_SIGNING_IDENTITY="Developer ID Application: Toby Lee (XXXXX)" \
#     Scripts/sign.sh /path/to/CCPluginManager.app
#
# 환경변수:
#   CC_PM_SIGNING_IDENTITY (필수): codesign --sign 에 전달할 인증서 이름
#   CC_PM_ENTITLEMENTS (옵션): entitlements.plist 경로. 기본은 본 스크립트와 동일 디렉토리.

set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "사용법: $0 <path/to/App.app>" >&2
  exit 1
fi

IDENTITY="${CC_PM_SIGNING_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
  echo "❌ CC_PM_SIGNING_IDENTITY 환경변수 필요." >&2
  echo "   예: 'Developer ID Application: Toby Lee (TEAMID12345)'" >&2
  echo "   확인: security find-identity -v -p codesigning" >&2
  exit 1
fi

ENTITLEMENTS="${CC_PM_ENTITLEMENTS:-$(dirname "$0")/entitlements.plist}"
if [[ ! -f "${ENTITLEMENTS}" ]]; then
  echo "⚠️  entitlements 파일 없음: ${ENTITLEMENTS} — 빈 entitlements 로 서명." >&2
  ENTITLEMENTS=""
fi

echo "🔐 서명: ${APP_PATH}"
echo "   Identity: ${IDENTITY}"
[[ -n "${ENTITLEMENTS}" ]] && echo "   Entitlements: ${ENTITLEMENTS}"

# --options runtime: Hardened Runtime 활성 (공증 필수 조건)
# --timestamp: Apple Timestamp Authority 서명 (공증 필수 조건)
# --deep: 번들 내부 nested 바이너리까지 서명 — 큰 번들에선 금지 권고지만 SwiftUI 앱 규모엔 OK
codesign --force \
  --options runtime \
  --timestamp \
  --deep \
  ${ENTITLEMENTS:+--entitlements "${ENTITLEMENTS}"} \
  --sign "${IDENTITY}" \
  "${APP_PATH}"

echo "🔍 서명 검증..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose=2 "${APP_PATH}" || {
  echo "⚠️  spctl assess 실패 — 공증 전엔 정상. notarize 후 다시 검증."
}

echo "✅ 서명 완료: ${APP_PATH}"
