#!/usr/bin/env bash
# sparkle-keygen.sh — Sparkle EdDSA 키 페어 1회 생성.
#
# 출력:
#   - Public key  → echo  (Info.plist 의 SUPublicEDKey 에 붙여넣기)
#   - Private key → Keychain 에 자동 저장 (Sparkle 의 generate_keys 동작)
#
# 사전:
#   brew install --cask sparkle
#   또는 https://sparkle-project.org 의 Sparkle SDK 다운로드.
#
# 안전:
#   private key 는 절대 git 커밋 금지. CI 는 별도 secret 으로 주입.

set -euo pipefail

SPARKLE_BIN="${SPARKLE_BIN:-}"
if [[ -z "${SPARKLE_BIN}" ]]; then
  for candidate in \
      "/Applications/Sparkle.app/Contents/MacOS/generate_keys" \
      "$(brew --prefix 2>/dev/null)/Caskroom/sparkle/*/bin/generate_keys"; do
    if [[ -x "${candidate}" ]]; then
      SPARKLE_BIN="${candidate}"
      break
    fi
  done
fi

if [[ -z "${SPARKLE_BIN}" || ! -x "${SPARKLE_BIN}" ]]; then
  cat >&2 <<EOF
❌ generate_keys 바이너리를 찾을 수 없음.
   다음 중 하나를 시도:
     1) brew install --cask sparkle
     2) SPARKLE_BIN=/path/to/generate_keys $0
EOF
  exit 1
fi

echo "📦 Sparkle key 생성: ${SPARKLE_BIN}"
"${SPARKLE_BIN}"

cat <<'EOF'

✅ 다음 작업:
   1) 위 출력의 Public key 를 App 의 Info.plist 에 추가:
        <key>SUPublicEDKey</key>
        <string>...</string>
   2) Private key 는 macOS Keychain 에 자동 저장됨.
      CI/CD 는 `sign_update` 도구로 서명 시 사용.
   3) GitHub Releases 에 dmg 업로드 후 appcast.xml 갱신은
      Scripts/release.sh 가 처리.
EOF
