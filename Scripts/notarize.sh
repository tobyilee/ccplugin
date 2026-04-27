#!/usr/bin/env bash
# notarize.sh — Apple notarytool 로 dmg 공증 + stapler.
#
# 사전:
#   xcrun notarytool store-credentials cc-pm-notary \
#     --apple-id "tobyilee@gmail.com" \
#     --team-id "TEAMID12345" \
#     --password "app-specific-password"
#
# 사용법:
#   CC_PM_NOTARY_PROFILE=cc-pm-notary Scripts/notarize.sh /path/to/foo.dmg

set -euo pipefail

DMG="${1:-}"
if [[ -z "${DMG}" || ! -f "${DMG}" ]]; then
  echo "사용법: $0 <path.dmg>" >&2
  exit 1
fi

PROFILE="${CC_PM_NOTARY_PROFILE:-}"
if [[ -z "${PROFILE}" ]]; then
  echo "❌ CC_PM_NOTARY_PROFILE 환경변수 필요." >&2
  echo "   사전 등록: xcrun notarytool store-credentials <profile-name> ..." >&2
  exit 1
fi

echo "📤 공증 제출: ${DMG} (profile: ${PROFILE})"
xcrun notarytool submit "${DMG}" \
  --keychain-profile "${PROFILE}" \
  --wait

echo "📎 Stapler — 공증 ticket 을 dmg 에 첨부..."
xcrun stapler staple "${DMG}"

echo "🔍 검증..."
xcrun stapler validate "${DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"

echo "✅ 공증 + stapler 완료: ${DMG}"
