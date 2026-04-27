#!/usr/bin/env bash
# build-dmg.sh — 서명된 .app 으로부터 배포 dmg 생성.
#
# 사용법:
#   Scripts/build-dmg.sh /path/to/CCPluginManager.app [output.dmg]

set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "사용법: $0 <path/to/App.app> [output.dmg]" >&2
  exit 1
fi

APP_NAME="$(basename "${APP_PATH}" .app)"
OUT="${2:-${APP_PATH%.app}.dmg}"

# Staging 디렉토리 — Applications 심볼릭 링크 + .app 만 포함.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp -R "${APP_PATH}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

# UDZO: 압축, 읽기전용. 배포 표준.
echo "📦 dmg 생성: ${OUT}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  "${OUT}"

# dmg 자체에도 서명 (선택 — 공증에 dmg 통째로 제출 시 권장).
if [[ -n "${CC_PM_SIGNING_IDENTITY:-}" ]]; then
  echo "🔐 dmg 서명..."
  codesign --force --sign "${CC_PM_SIGNING_IDENTITY}" --timestamp "${OUT}"
fi

echo "✅ 생성 완료: ${OUT}"
echo "   다음 단계: Scripts/notarize.sh ${OUT}"
