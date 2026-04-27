# Claude Code Plugin Manager

macOS 메뉴바 native 앱. `~/.claude/` 의 플러그인·마켓·스킬·훅을 한 화면에서 관리.

> 상세 사양은 [PRD.md](PRD.md) 참조 (v2.2, ~2,000줄).

## 주요 기능

- **인벤토리** — 설치된 플러그인을 알파벳순 또는 마켓별 그룹 보기로 토글 (Installed 탭).
- **카탈로그 검색** — Browse 탭 진입 시 자동 포커스된 검색창에서 이름·마켓·설명 substring 필터링.
- **마켓 라이프사이클** — Add / Refresh / Remove / Auto-Update 토글 (cascade 확인 dialog 포함).
- **플러그인 라이프사이클** — Install (scope 선택) / Uninstall (`--keep-data`) / Update / Enable·Disable.
- **버전 가시성** — 플러그인 버전 컬럼 + 마켓별 `metadata.version` 캡슐 + 마지막 refresh 시각.
- **자동 새로고침** — `~/.claude/` 트리 변경을 FSEvents 로 감지해 debounced reload.
- **안전 mutation** — proper-lockfile 호환 FileLock + passthrough 보존 + 자동 백업.
- **진단 + 정리** — Diagnostics 탭에서 무결성 검사 + Orphaned Cache cleanup.

## 빠른 시작 (개발)

```bash
# PluginCore 단위 테스트 (97 tests)
cd Packages/PluginCore && swift test

# App 빌드
cd Packages/App && swift build

# 메뉴바 앱 실행 (개발 모드 — Dock 미노출, ⌘Q 로 종료)
cd Packages/App && swift run CCPluginManager
```

요구사항: macOS 13+, Swift 6.0 toolchain, `claude` CLI 2.1+.

## 로컬 설치 (/Applications + 로그인 자동 실행)

배포 dmg 가 아니라 본인 머신에 release 빌드를 빠르게 설치하는 dev 경로.
Apple Developer 인증서 불필요 (ad-hoc codesign).

```bash
# 빌드 → /Applications/CCPluginManager.app 설치 → 로그인 항목 등록
Scripts/install-local.sh

# 로그인 항목 등록 없이 설치만
Scripts/install-local.sh --no-login

# 제거 (로그인 항목 + /Applications 둘 다)
Scripts/install-local.sh --uninstall
```

스크립트가 하는 일:
1. `swift build -c release` (Packages/App)
2. `.app` 번들 조립 — `Info.plist` 에 `LSUIElement=YES` (Dock 미노출, 메뉴바만)
3. `codesign --sign -` ad-hoc 서명 (배포용 X)
4. `xattr -dr com.apple.quarantine` — 첫 실행 시 Gatekeeper "확인되지 않은 개발자" 다이얼로그 회피
5. `osascript` 로 System Events 의 login item 추가 (`hidden:true`)

처음 실행 시 macOS 가 ​File System / Apple Events 권한을 한 번 묻습니다 — 허용하면 다음 부팅부터 메뉴바에 자동 등장.

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
│   │   └── Tests/          # swift-testing (97 tests)
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

## 메인 윈도우 탭

`NavigationSplitView` 기반 사이드바 + detail. 모든 탭은 FSEvents 로 자동 새로고침되며, 우상단 Refresh 로 수동 reload.

### Installed
설치된 플러그인 인벤토리. `installed_plugins.json` (V2) + `settings.json` + `plugin.json` + 디렉토리 스캔의 4-source 합성.

- **두 가지 보기 (`@AppStorage` 로 영속화)**
  - **Alphabetical** (기본): plugin id 기준 정렬된 `Table` — Plugin / Version / Scope / Enabled / Components 컬럼.
  - **By Marketplace**: `List` + `Section` — 마켓별로 그룹화, 헤더에 `🛍 marketplace · N plugins`. 마켓이 없는 항목은 `(no marketplace)` 로 끝에.
- 상단 search 바로 이름·설명 필터링 (대소문자 무관 substring).
- Toggle 로 enable/disable (user-scope 만, settings.json 직접 flip — UX 우선, PRD §6.1). 다른 scope 는 hover 도움말로 안내.
- 컨텍스트 메뉴: Enable/Disable · Update · Uninstall (확인 dialog + `--keep-data` 옵션).

### Marketplaces
`known_marketplaces.json` + 각 마켓의 `marketplace.json` 합성 + user-intent autoUpdate (settings).

- 컬럼: Marketplace (이름 · v버전 캡슐 · source · "Updated 2 hours ago") / **Version** (`metadata.version`, 없으면 `—`) / Plugins / Auto-Update / 액션.
- Action bar: **Add Marketplace** (sheet — source/scope/sparse paths) · **Refresh All** (`claude plugin marketplace update`).
- Row action: Refresh / Auto-Update toggle (Optimistic UI) / Remove (cascade 확인 dialog).
- seed 마켓 / user settings 미선언 항목은 잠금 아이콘 + read-only 표시.

### Browse
모든 마켓 catalog cross-join + 설치 여부.

- 상단 **항상 노출되는 search bar**: `TextField` + 돋보기 + clear-X. 탭 진입 시 자동 포커스 (`@FocusState`) — 키보드만으로 즉시 필터링 가능.
- 두 가지 보기 (Installed 와 동일한 패턴, `@AppStorage` 로 영속화):
  - **Alphabetical**: 미설치 우선, 그다음 id 기준.
  - **By Marketplace**: 마켓별 `Section`. 헤더에 `🛍 marketplace · v버전 · N plugins · X installed` (installed 카운트는 0 보다 클 때만 초록색).
- 필터 substring 매칭 대상: 이름 · 마켓 · 설명.
- Install 버튼 → scope 선택 sheet → CLI bridge.

### User Assets / Hooks / Diagnostics
- **User Assets**: `~/.claude/{commands,agents,skills}` 직접 스캔.
- **Hooks**: settings.json 의 hooks 트리 + Add/Remove sheet.
- **Diagnostics**: 디스크 무결성 체크 + Orphaned Cache cleanup (Q2 spike leftover 처리).

## 마일스톤 진행 상황

- ✅ M0 (spike + 인프라) — Q2/Q8 spike 완료, 97개 unit test
- ✅ M1 (read-only inventory) — Installed/Marketplaces/Browse 탭, FSEvents 자동 새로고침
- ✅ M2 (marketplace mutation) — Add/Refresh/Remove/Toggle autoUpdate, FileLock, BackupService
- ✅ M3 (plugin lifecycle) — install/uninstall/enable/disable/update + ReloadHint banner
- ✅ M4 (user assets + diagnostics) — UserAssets/Hooks/Diagnostics 탭, OrphanedCache cleanup
- ✅ UX iteration — 마켓별 그룹 view, 항상 노출 검색 바, 마켓·플러그인 버전 표시
- ⏸ 배포 — Apple Developer 인증서, Sparkle 통합, Homebrew Cask (수동)

## 데이터 모델 메모

`MarketplaceCatalog.metadata.version` 은 일부 마켓 (e.g. `openai-codex` v1.0.4) 에서만 declared 됨. UI 는 `MarketplaceRow.version` (Optional) 으로 받아 nil 일 때 `—` 표시 — 마켓 schema 의 micro-drift 를 강제로 통일하지 않고 있는 그대로 surface.

`description` 도 root / `metadata.description` 두 위치 모두 합법 — `effectiveDescription` 헬퍼로 root 우선 fallback.

## 관련 문서

- [PRD.md](PRD.md) — 풀 사양 (모든 구현 결정의 근거)
- [spike/REPORT.md](spike/REPORT.md) — M0 spike 결과 (CLI 표면 검증, lockfile 정책, Q2/Q8 RESOLVED)
