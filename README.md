# Claude Code Plugin Manager

macOS 메뉴바 native 앱. `~/.claude/` 의 플러그인·마켓·스킬·훅을 한 화면에서 관리.

> 상세 사양은 [PRD.md](PRD.md) 참조 (v2.2, ~2,000줄).

## 빠른 시작 (개발)

```bash
# PluginCore 단위 테스트 (95 tests)
cd Packages/PluginCore && swift test

# App 빌드
cd Packages/App && swift build

# 메뉴바 앱 실행 (개발 모드 — Dock 미노출, ⌘Q 로 종료)
cd Packages/App && swift run CCPluginManager
```

요구사항: macOS 13+, Swift 6.0 toolchain, `claude` CLI 2.1+.

## 디렉토리 구조

```
ccplugin/
├── PRD.md                   # 사양 (v2.2)
├── README.md                # 이 파일
├── Packages/
│   ├── PluginCore/         # Foundation-only 비-UI 라이브러리
│   │   ├── Sources/
│   │   │   ├── Schemas/    # zod 스키마 Swift Codable mirror
│   │   │   ├── Readers/    # disk JSON 파서 (actor 격리)
│   │   │   ├── Writers/    # passthrough-preserving mutation
│   │   │   ├── Bridge/     # claude CLI 위임 (ProcessRunner)
│   │   │   ├── Locking/    # proper-lockfile 호환 + backup
│   │   │   ├── Diagnostics/# 가벼운 disk 진단 + cache cleanup
│   │   │   ├── Watching/   # FSEvents
│   │   │   ├── Paths/      # ~/.claude 경로 해석
│   │   │   └── IDs/        # 정규식 + 사칭 차단
│   │   └── Tests/          # swift-testing (95 tests)
│   └── App/                 # SwiftUI MenuBarExtra
│       └── Sources/App/
│           ├── AppMain.swift      # @main + AppDelegate
│           ├── UI/                # SwiftUI views
│           └── ViewModels/        # 4-source 합성 + actions
├── Scripts/                 # 배포 파이프라인
│   ├── sparkle-keygen.sh    # Sparkle EdDSA 키
│   ├── sign.sh              # Developer ID + Hardened Runtime
│   ├── build-dmg.sh         # UDZO dmg
│   ├── notarize.sh          # notarytool + stapler
│   ├── release.sh           # orchestrator
│   └── entitlements.plist
├── spike/                   # M0 spike 결과 + fixtures
└── .github/workflows/       # CI
```

## 아키텍처 핵심

PRD §1.2 의 **3-Layer 모델** 기반:

| Layer | 위치 | 본 매니저 책임 |
|---|---|---|
| 1 (intent) | `~/.claude/settings.json` | mutate 가능 |
| 2 (materialization) | `~/.claude/plugins/` | mutate (CLI 위임 우선) |
| 3 (active) | Claude 세션의 in-process AppState | reload-plugins 안내만 |

매니저는 Layer 1+2 만 다룸. mutation 후 자동 reload-plugins 는 불가능 → 사용자에게 배너로 안내.

## 마일스톤 진행 상황

- ✅ M0 (spike + 인프라) — Q2/Q8 spike 완료, 95개 unit test
- ✅ M1 (read-only inventory) — Installed/Marketplaces/Browse 탭, FSEvents 자동 새로고침
- ✅ M2 (marketplace mutation) — Add/Refresh/Remove/Toggle autoUpdate, FileLock, BackupService
- ✅ M3 (plugin lifecycle) — install/uninstall/enable/disable/update + ReloadHint banner
- ✅ M4 (user assets + diagnostics) — UserAssets/Hooks/Diagnostics 탭, OrphanedCache cleanup
- ⏸ 배포 — Apple Developer 인증서, Sparkle 통합, Homebrew Cask (수동)

## 관련 문서

- [PRD.md](PRD.md) — 풀 사양 (모든 구현 결정의 근거)
- [spike/REPORT.md](spike/REPORT.md) — M0 spike 결과 (CLI 표면 검증, lockfile 정책, Q2/Q8 RESOLVED)
