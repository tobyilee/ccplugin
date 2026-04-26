# Claude Code Plugin Manager — PRD

> **Status**: Draft v2.2 (Mac native menubar app — post-M0 spike + Q2/Q8 destructive verification)
> **작성일**: 2026-04-26
> **개정일**:
> - 2026-04-26 (v1.0 → v2.0): TUI(ink) 폐기, macOS 메뉴바 native 앱으로 전환
> - 2026-04-26 (v2.0 → v2.1): M0 spike 결과 반영 — CLI/disk schema gap, marketplace `refresh`/`update` 명명, lockfile 비대칭 정책 등
> - 2026-04-26 (v2.1 → v2.2): Q2 (cascade) / Q8 (userConfig) 후속 spike 결과 — cascade 자동, cache orphan 만 매니저 책임. userConfig 는 enable 시점 prompt + Keychain
> **소유자**: Toby Lee
> **분석 기준 코드**: `@anthropic-ai/claude-code` (소스 위치: `/Users/tobylee/workspace/ai/claudecode/src`, 분석 시점 commit 13615cf)
> **분석 기준 CLI**: `claude` 2.1.119
> **대상 독자**: 본 매니저 앱을 새 프로젝트 폴더에서 처음 빌드할 개발자
> **타겟 플랫폼**: macOS 13+ (Ventura) — 메뉴바 상주 SwiftUI/AppKit native 앱
> **참고**: M0 spike 결과는 `spike/REPORT.md` 및 `spike/cli-fixtures/` 참조

---

## 0. TL;DR

`~/.claude` 사용자 레벨에 설치된 **Claude Code 플러그인·마켓플레이스·스킬·에이전트·커맨드·훅**을 **macOS 메뉴바에서 한 클릭으로** 관리하는 native 앱을 만든다.

**형태**: 메뉴바(Status Bar)에 상주 → 클릭 시 빠른 상태 popover, 추가 클릭으로 풀 매니저 윈도우. Dock 미노출(`LSUIElement = YES`).

핵심 기능:
1. 설치된 플러그인의 enable/disable, install/uninstall, update
2. Marketplace 등록(add)/제거(remove)/갱신(refresh)/auto-update 토글
3. 마켓에서 플러그인 탐색 후 install
4. 사용자 직접 작성한 skill/agent/command/hook 의 CRUD
5. 충돌·오류 진단 (loadAllPlugins errors, blocklist, orphaned cache)
6. 메뉴바 상시 표시: 활성 플러그인 수 / 에러 / 사용 가능한 업데이트

핵심 제약:
- Claude Code 의 **3-layer 모델** (intent / disk / runtime) 을 준수한다 — runtime hot-swap 은 본 매니저에서 불가능, 사용자에게 `/reload-plugins` 안내가 필요.
- 핵심 mutation 은 **`claude` CLI 자식 프로세스를 통해 위임**하는 것이 1차 권장 (CLI Bridge 방식). 직접 파일 매니저 방식은 2차로만 검토.
- 자식 프로세스 호출은 **반드시 Swift `Process` 의 `executableURL` + `arguments: [String]` 패턴만 사용**(쉘 보간 금지). `/bin/sh -c`, `launchPath` (deprecated) 사용 금지. 사용자 입력은 모두 `arguments` 배열로 전달.
- `installed_plugins.json` V2 schema, `known_marketplaces.json`, `settings.json` 의 `enabledPlugins` / `extraKnownMarketplaces` 필드는 **읽기용 미러만 자체 보유**, 쓰기는 가능한 한 CLI 에 맡긴다.
- **Sandbox OFF + Developer ID 배포** 채택 — Mac App Store 비대상. Homebrew Cask + dmg 직접 배포.
- **GUI 앱 PATH 상속 부재** 문제: `claude` CLI 경로는 `CC_PM_CLAUDE_BIN` env → 알려진 경로 스캔 → 로그인 셸 위임 → 사용자 선택 fallback chain.

MVP 기간: **8주** (v1.0의 4주 → Mac native 인프라 비용 +4주: 공증 파이프라인, Sparkle 자동 업데이트, 코드 사이닝, dmg 제작).

---

## 1. 배경 (Background)

### 1.1 Claude Code 플러그인 시스템 개요

Claude Code 는 사용자 레벨(`~/.claude/`) 또는 프로젝트 레벨(`<repo>/.claude/`) 의 **플러그인**으로 기능을 확장한다. 플러그인 1개는 다음 요소를 한꺼번에 묶어 제공할 수 있다:

| 컴포넌트 | 위치 (플러그인 내부) | 역할 |
|---|---|---|
| **commands** | `commands/*.md` 또는 manifest `commands` 필드 | 슬래시 명령 (`/foo:bar`) |
| **agents** | `agents/*.md` 또는 manifest `agents` 필드 | 서브에이전트 정의 |
| **skills** | `skills/<name>/SKILL.md` 또는 manifest `skills` 필드 | 자동·수동 호출 가능 스킬 |
| **hooks** | `hooks/hooks.json` 또는 manifest `hooks` 필드 | PreToolUse/PostToolUse/SessionStart 등 후크 |
| **mcpServers** | `.mcp.json` / manifest `mcpServers` / `.mcpb` 번들 | MCP 서버 등록 |
| **lspServers** | `.lsp.json` 또는 manifest `lspServers` | LSP 통합 |
| **outputStyles** | `output-styles/*` | 출력 스타일 |
| **channels** | manifest `channels` | 메시지 채널(Telegram 등) MCP 바인딩 |
| **userConfig** | manifest `userConfig` | 사용자 입력 옵션 (sensitive 키체인 저장) |

### 1.2 3-Layer 아키텍처

Claude Code 소스 (`src/utils/plugins/refresh.ts:1`) 의 주석에 명시된 모델:

```
Layer 1: intent          ←  ~/.claude/settings.json 의 enabledPlugins / extraKnownMarketplaces
Layer 2: materialization ←  ~/.claude/plugins/ 디스크 상태 (reconciler.ts 가 동기화)
Layer 3: active          ←  AppState (refresh.ts 가 in-process 로 핫스왑)
```

| 액션 | Layer 1 | Layer 2 | Layer 3 |
|---|---|---|---|
| enable / disable | mutate | – | reload 필요 |
| install / uninstall | mutate | mutate | reload 필요 |
| update | – | mutate | reload 필요 |
| add / remove marketplace | mutate (extraKnownMarketplaces) | mutate (clone/pull/rm) | reload 필요 |
| refresh marketplace | – | mutate (git pull) | reload 필요 |

> **PRD 원칙**: 본 매니저는 Layer 1·2 만 다룬다. Layer 3 hot-swap 은 동일 프로세스 안에서만 가능하므로, 변경 후에는 **"Claude Code 세션에서 `/reload-plugins` 실행"** 안내 배너를 표시한다.

### 1.3 핵심 파일 구조 (실측)

```
~/.claude/
├── settings.json
│   ├── enabledPlugins: { "name@market": boolean }
│   ├── extraKnownMarketplaces: { name: { source, autoUpdate? } }
│   ├── hooks: { event: [{ matcher, hooks: [...] }] }
│   ├── permissions: {...}
│   ├── env: {...}
│   └── statusLine: { type, command }
│
├── plugins/
│   ├── installed_plugins.json   # V2 schema
│   ├── known_marketplaces.json
│   ├── blocklist.json
│   ├── install-counts-cache.json
│   ├── marketplaces/
│   │   ├── claude-plugins-official/
│   │   │   ├── .claude-plugin/marketplace.json
│   │   │   ├── plugins/
│   │   │   └── external_plugins/
│   │   ├── omc/
│   │   ├── ralph-marketplace/
│   │   └── toby-plugins/
│   ├── cache/
│   │   └── {marketplace}/{plugin}/{version}/
│   │       └── .claude-plugin/plugin.json
│   └── data/
│       └── {plugin}-{marketplace}/   # 플러그인 영속 데이터
│
├── skills/        # 사용자 직접 작성 + 플러그인 관리 혼재
├── agents/        # 사용자 직접 작성 (현재 비어있음)
├── commands/      # 사용자 직접 작성 (현재 비어있음)
└── hud/           # statusLine 구현체
```

### 1.4 Plugin / Marketplace 식별자 규칙

- **Plugin ID 정규식** (`schemas.ts:1339-1346`): `^[a-z0-9][-a-z0-9._]*@[a-z0-9][-a-z0-9._]*$` → 형식 `name@marketplace`
- 예약 마켓 이름: `inline` (세션 `--plugin-dir`), `builtin` (CLI 빌트인)
- 공식 마켓 사칭 차단 정규식 (`schemas.ts:71`):
  ```regex
  (?:official[^a-z0-9]*(anthropic|claude)|(?:anthropic|claude)[^a-z0-9]*official|^(?:anthropic|claude)[^a-z0-9]*(marketplace|plugins|official))
  ```
- 공식 예약 이름 화이트리스트 (`schemas.ts:19-28`):
  ```
  claude-code-marketplace, claude-code-plugins, claude-plugins-official,
  anthropic-marketplace, anthropic-plugins, agent-skills, life-sciences,
  knowledge-work-plugins
  ```
  → 이 이름들은 `github.com/anthropics/*` 출처만 허용.

### 1.5 Scope 모델

설치 위치(scope)는 4단계 + 1세션:

| Scope | 영속 위치 | 본 매니저 지원 |
|---|---|---|
| `managed` | OS별 정책 경로 (`/Library/Application Support/ClaudeCode/managed-settings.json` 등) | **읽기만** (수정 불가, 엔터프라이즈) |
| `user` | `~/.claude/settings.json` | ✅ 기본 |
| `project` | `<cwd>/.claude/settings.json` | ✅ |
| `local` | `<cwd>/.claude/settings.local.json` | ✅ |
| `flag` | 메모리(--plugin-dir) | ❌ 세션 한정, 영속화 불가 |

### 1.6 Source 종류

#### Plugin Source (`PluginSourceSchema`, `schemas.ts:1062-1161`)

| `source` | 추가 필드 | 설명 |
|---|---|---|
| `'./...'` | – | 마켓 저장소 내부 상대 경로 (string 형) |
| `'github'` | `repo`, `ref?`, `sha?` | GitHub `owner/repo` 단축형 |
| `'git-subdir'` | `url`, `path`, `ref?`, `sha?` | 모노레포 sparse checkout |
| `'url'` | `url`, `ref?`, `sha?` | 일반 git URL (Azure DevOps, CodeCommit 등) |
| `'npm'` | `package`, `version?`, `registry?` | npm 패키지 |
| `'pip'` | `package`, `version?`, `registry?` | Python 패키지 (PyPI) |

#### Marketplace Source (`MarketplaceSourceSchema`, `schemas.ts:906-1044`)

| `source` | 추가 필드 |
|---|---|
| `'url'` | `url`, `headers?` |
| `'github'` | `repo`, `ref?`, `path?`, `sparsePaths?` |
| `'git'` | `url`, `ref?`, `path?`, `sparsePaths?` |
| `'npm'` | `package` |
| `'file'` | `path` (로컬 marketplace.json) |
| `'directory'` | `path` (로컬 디렉토리) |
| `'hostPattern'` | `hostPattern` (정책용 정규식) |
| `'pathPattern'` | `pathPattern` (정책용 정규식) |
| `'settings'` | `name`, `plugins[]`, `owner?` (인라인 선언) |

### 1.7 Claude CLI 커맨드 표면 (위임 대상) — M0 spike 실측

`claude` 2.1.119 의 `--help` 출력으로 직접 검증한 결과 (PRD v2.0 의 추측 명세를 갱신):

```
# 플러그인 라이프사이클
claude plugin list                        [--available] [--json]
                                          # --available 은 --json 강제
claude plugin install <plugin>[@market]   [-s, --scope user|project|local]   # default user
claude plugin uninstall <plugin>          [-s, --scope user|project|local] [--keep-data]
claude plugin enable <plugin>             [-s, --scope ...]                  # 미지정 시 auto-detect
claude plugin disable [<plugin>]          [-s, --scope ...] [-a, --all]
claude plugin update <plugin>             [-s, --scope user|project|local|managed]
                                          # "restart required to apply"
claude plugin validate <path>
claude plugin tag [<path>]                # 릴리즈용. 매니저 비대상

# 마켓플레이스 관리
claude plugin marketplace list             [--json]
claude plugin marketplace add <source>     [--scope user|project|local]
                                           [--sparse <paths...>]
claude plugin marketplace remove|rm <name>
claude plugin marketplace update [<name>]  # 이름 미지정 시 전체. (= refresh)
```

**Spike 가 v2.0 추측을 갱신한 항목** (강조):

| v2.0 PRD 가정 | 실측 결과 |
|---|---|
| `marketplace refresh [name]` 또는 `--all` | ❌ **존재하지 않음** — `marketplace update [name]` 가 그 역할. 이름 미지정 시 전체 갱신. |
| `marketplace auto-update <name> on\|off` | ❌ **CLI 없음** — autoUpdate 토글은 settings.json `extraKnownMarketplaces[name].autoUpdate` 직접 mutation 만 가능. |
| `marketplace add <name> <source-spec>` | ⚠️ 시그니처 다름 — 첫 인자가 `<source>` 1개. `--ref`, `--auto-update`, `--path` 옵션 없음. `--sparse` 만 노출. |
| `disable-all` (별도 서브커맨드) | ❌ — `disable -a, --all` 플래그로 통합. |

**`--json` 출력 스키마**: §11.2 의 캡처는 `spike/cli-fixtures/{plugin-list,marketplace-list}.json` 으로 확정 (M1 시작 시 `Tests/Fixtures/cli/` 로 이관). 출력은 disk JSON 의 **부분집합** — §6.1 결정 표 재확인.

---

## 2. 비전 & 목표 (Vision & Goals)

### 2.1 Vision

> "Claude Code 사용자가 자신의 `~/.claude/` 환경 전체 — 플러그인, 마켓, 사용자 자산, 훅 — 를 **CLI 외워서 입력하지 않고** 한 화면에서 안전하게 통제할 수 있게 한다."

### 2.2 사용자 페르소나

| Persona | 특징 | 핵심 페인 포인트 |
|---|---|---|
| **Power User (Toby)** | 26개+ 플러그인, 6개+ 마켓 운용, 자체 마켓 보유 | 어떤 플러그인이 켜져 있고 어디서 왔는지 추적 어려움, 충돌 진단 시간 ↑ |
| **Plugin 개발자** | 자기 마켓에 플러그인 발행 + 로컬 dev | 로컬 ↔ 배포 토글, marketplace.json 검증 빠르게 |
| **신규 사용자** | 마켓에서 플러그인 둘러보고 install | `claude plugin marketplace add` 신택스 외우기 어려움, 어떤 마켓이 있는지 모름 |

### 2.3 Goals (MVP)

- **G1**: 설치된 플러그인 26개 내외를 단일 화면에 출력하고 enable/disable/uninstall/update 가능 (5초 이내 반영).
- **G2**: 마켓 6개 내외를 단일 화면에서 add/remove/refresh, autoUpdate 토글.
- **G3**: 마켓 → 플러그인 리스트 브라우징 후 install (scope 선택 가능).
- **G4**: `~/.claude/settings.json` 의 `hooks` 블록을 GUI/TUI 로 CRUD.
- **G5**: 사용자 작성 skill/agent/command 파일을 CRUD (플러그인 관리 자산은 read-only 배지 표시).
- **G6**: 모든 mutating 액션은 사전 확인 다이얼로그 + 실패 시 롤백 가능.

### 2.4 Non-Goals (MVP)

- 플러그인 **저작/스캐폴딩** (이미 `claude plugin validate` + `plugin-dev` 플러그인이 존재)
- MCP 서버 직접 실행/디버깅 (Claude Code 가 담당)
- Claude Code 자체 업그레이드 (npm/brew 영역)
- 멀티 머신 동기화 (별도 SaaS 영역)
- Web 기반 마켓플레이스 검색 UI (브라우징은 로컬 캐시 기반만)

---

## 3. 사용자 시나리오 (User Stories)

### S1. 충돌 진단
"Claude Code 가 갑자기 `/foo` 명령을 못 찾는다. 어떤 플러그인이 그 명령을 제공하는지, 그 플러그인이 disabled 상태인지 확인하고 싶다."

→ Installed 탭에서 플러그인을 펼치면 그 플러그인이 제공하는 commands/agents/skills 목록이 표시된다. `foo` 검색 시 매칭. enabled/disabled 상태가 한 줄로 표시.

### S2. 마켓 추가
"동료가 자기 마켓 `https://github.com/foo/bar.git` 을 공유해줬다. 추가하고 그 안의 플러그인 하나만 install 하고 싶다."

→ Marketplaces 탭 → "Add Marketplace" → URL 붙여넣기 → 자동 클론 + 검증 → Browse 탭으로 자동 이동 → 플러그인 1개 선택 → "Install at user scope".

### S3. Hook 추가
"매 SessionStart 마다 내 dotfiles 동기화 스크립트를 돌리고 싶다."

→ Hooks 탭 → SessionStart 이벤트 선택 → "Add hook" → matcher 비워두고 command 에 절대 경로 입력 → save → settings.json 갱신 + 미리보기.

### S4. Update 일괄
"어제 마켓들이 새 버전을 냈다. 다 한 번에 갱신하고 싶다."

→ Marketplaces 탭 상단 "Refresh All" 버튼 → 진행률 표시 + 각 마켓 결과 표시 → 이어서 "Update plugins from refreshed markets" 다이얼로그 → 일괄 update.

### S5. 안전한 제거
"오래 안 쓴 플러그인을 정리하고 싶은데, 그 플러그인이 다른 플러그인에 의존되고 있을지 모른다."

→ Installed 탭 → 플러그인 우클릭 → "Uninstall" → 사전에 reverse-dependents 분석 (`pluginOperations.ts:findReverseDependents`) → 의존된다면 경고 + 차단/강제 옵션.

### S6. 사용자 스킬 작성
"`~/.claude/skills/my-helper/SKILL.md` 를 새로 만들고 싶다."

→ Skills 탭 → "Create user skill" → name 입력 → 템플릿 SKILL.md 생성 → 에디터로 편집.

---

## 4. 기능 요구사항 (Functional Requirements)

### F1. 플러그인 인벤토리 (Installed)

#### F1.1 List
- **Source 합성** (M0 spike 결과 — CLI 단독으론 부족):
  - **CLI**: `claude plugin list --json` → `id`, `version`, `scope`, `enabled`, `installPath`, `installedAt`, `lastUpdated`, `mcpServers`
  - **Disk** `installed_plugins.json` V2 → `gitCommitSha`, V2 multi-scope 배열
  - **Disk** cache 의 `<installPath>/.claude-plugin/plugin.json` → manifest 의 description/author/keywords/dependencies
  - **Disk** cache 디렉토리 스캔 → commands/agents/skills/hooks 카운트 (CLI 미노출, manifest 의 명시 필드 + 표준 디렉토리 매핑 합성)
- **출력 컬럼**: `name@market`, version, scope, enabled (✓/✗), source type, last updated, errors.
- **세부 펼침**: manifest description, author, repository, homepage, keywords, 제공 components 카운트 (commands/agents/skills/hooks/mcp/lsp), 의존 플러그인 목록.
- **필터**: scope, marketplace, enabled-only, has-errors-only.
- **검색**: name 부분 일치, command/agent/skill 이름 검색.
- **컴포넌트 카운트 우선순위 ↑** (M0): CLI 가 mcpServers 만 노출하므로 `PluginManifestReader` (PRD §6.2) 가 M1 critical path. cache 누락 시 카운트는 빈 값 + warning 배지.

#### F1.2 Enable / Disable
- **CLI bridge**: `claude plugin enable <id> --scope <s>` / `disable`.
- **Direct fallback**: `enabledPlugins[id] = true|false` 만 패치, 없는 키는 추가하지 않음.
- **Constraints**:
  - `managed` scope 플러그인은 disable 불가 (CLI 가 거절).
  - dependencies 가 있는 플러그인 disable 시 reverse-dependents 경고.

#### F1.3 Uninstall
- **CLI bridge**: `claude plugin uninstall <id> --scope <s> [--keep-data]`.
- **사전 확인**: reverse-dependents, scope, 데이터 유지 여부, 캐시 삭제 여부.
- **데이터 삭제**: 기본 `~/.claude/plugins/data/{plugin}-{market}/` 삭제, `--keep-data` 시 유지.
- **결과**:
  - `installed_plugins.json` entry 1개 제거 (배열에서)
  - `enabledPlugins[id]` 키 제거
  - 캐시 폴더 orphan 마킹 (`markPluginVersionOrphaned`)

#### F1.4 Update
- **CLI bridge**: `claude plugin update <id> --scope <s>`.
- **사전 표시**: 현재 version / gitCommitSha vs 마켓 최신.
- **진행 표시**: clone/pull, 새 버전 폴더 생성, manifest 재검증, `installed_plugins.json` 갱신.
- **rollback**: 실패 시 이전 cache 폴더 유지.

#### F1.5 Bulk
- **Bulk enable/disable**: 다중 선택 후 일괄 토글.
- **Bulk update**: "Update all" — 모든 user-scope 플러그인.
- **Bulk uninstall**: 다중 선택 (reverse-dependents 가 모두 선택 안에 포함될 때만 허용).

### F2. Marketplace 관리

#### F2.1 List
- **Source**: `known_marketplaces.json` × `extraKnownMarketplaces` 머지.
- **컬럼**: name, source type/URL, lastUpdated, autoUpdate, declared scope (user/project/local), is-official, is-seed (read-only).
- **세부**: 마켓이 보유한 플러그인 N개, 그 중 설치된 K개.

#### F2.2 Add (2단계 트랜잭션 — M0 spike 반영)

> CLI `marketplace add` 가 `--scope`, `--sparse` 만 노출 → ref/path/autoUpdate 등은 매니저가 직접 settings.json 백필.

- **Forms** (source 종류별 다른 입력 — UI 는 v2.0 그대로 유지):
  - GitHub: `owner/repo` 단축, ref?, path?, sparsePaths?
  - Git URL: full URL, ref?, path?, sparsePaths?
  - URL (json): 직접 marketplace.json URL, headers?
  - File / Directory: 로컬 경로
  - NPM: package name
- **백엔드 트랜잭션** (Add Marketplace sheet 의 [Add] 클릭 시):
  1. **CLI bridge**: `claude plugin marketplace add <source> --scope <s> [--sparse <paths>]`.
     - `<source>` 는 source type 별로 직렬화: GitHub `owner/repo`, Git URL `https://...`, File `/abs/path`, NPM `@scope/pkg`.
     - 결과로 `known_marketplaces.json` + settings.json `extraKnownMarketplaces[name]` 자동 생성.
  2. **Direct settings.json patch** (필요 시):
     - 사용자가 `ref`, `path`, `headers`, `autoUpdate` 등 입력했고 CLI 가 안 받았다면, settings.json 의 `extraKnownMarketplaces[name].source.{ref,path,...}` 또는 `.autoUpdate` 를 매니저가 직접 mutation.
     - settings.json 락 (PRD §10.4) 으로 보호.
  3. 실패 시 1단계까지만 성공한 부분 트랜잭션 → 보상: `claude plugin marketplace remove <name>` 으로 롤백.
- **검증** (CLI 호출 전 클라이언트 측):
  - 이름이 `MarketplaceNameGuard.isBlocked` 매칭 시 거절 (PRD §7.5).
  - 예약 이름은 `github.com/anthropics/*` 출처만.
  - 비ASCII 이름 거절 (homograph).

#### F2.3 Remove (cascade RESOLVED — v2.2)

> Q2 후속 spike (2026-04-26, `spike/REPORT.md` 부록) 로 검증: CLI 가 메타데이터 cascade 자동, **cache 디렉토리만 orphan** 으로 남김.

- **CLI bridge**: `claude plugin marketplace remove <name>` — 단일 호출로 충분.
- **사전 확인** (UI Alert): "이 마켓에서 설치한 플러그인 N개를 함께 제거합니다 — cache 디렉토리는 orphan 으로 남으며 Diagnostics 탭에서 정리할 수 있습니다 — 계속하시겠습니까?".
- **자동 cascade (CLI 가 처리)**:
  - ✅ `known_marketplaces.json` entry 제거
  - ✅ `settings.extraKnownMarketplaces[name]` 제거
  - ✅ `installed_plugins.json` 의 모든 소속 플러그인 entry 제거
  - ✅ `settings.enabledPlugins[*@market]` 모든 소속 키 제거
- **CLI 가 안 하는 것 — 매니저 책임**:
  - ❌ `~/.claude/plugins/cache/<market>/` orphan 디렉토리 → §F5 Diagnostics 의 `OrphanedCacheDetector` 가 노출 + "Clean all" 버튼 제공.
  - ❌ `~/.claude/plugins/data/<market>/` orphan (있다면) → 동상.
- **결론**: 매니저는 (1) 사용자 confirm → (2) `marketplace remove` 1회 호출 → (3) Diagnostics 탭으로 자동 이동 또는 popover 알림 "1 orphan cache cleanup available". 명시적 사전 uninstall 직렬화 ❌ 불필요.

#### F2.4 Refresh (= CLI `marketplace update`)

> v2.0 의 `marketplace refresh` 명세는 **존재하지 않는 명령** — M0 spike 검증.

- 단일: `claude plugin marketplace update <name>`.
- 전체: `claude plugin marketplace update` (이름 인자 생략).
- 진행률 + 각 마켓별 결과 (성공/실패/no-change). CLI stdout 라인 stream 파싱.

#### F2.5 Auto-update Toggle (Direct mutation only — CLI 미지원)

> v2.0 의 `auto-update <name> on|off` 는 **존재하지 않는 명령** — M0 spike 검증.

- **유일 경로**: settings.json `extraKnownMarketplaces[name].autoUpdate = true|false` 직접 mutation.
- settings.json 락 보호 (PRD §10.4).
- 공식 마켓 (예약 이름) 의 기본값은 Claude Code 의 reconciler 가 처리 — 매니저가 toggle UI 에 그 기본값을 표시하되 사용자가 명시적 override 가능.
- UI: Marketplaces 탭의 cell 내 SwiftUI `Toggle`. 즉시 반영 + 락 미획득 시 spinner.

### F3. Marketplace Browse → Install

#### F3.1 Browse
- 선택한 마켓의 `marketplace.json` 파싱 후 plugins[] 출력.
- 컬럼: name, description, category, tags, source 요약, 이미 설치 여부, install count (있으면).
- 플러그인 클릭 시 manifest 미리보기 (description, author, keywords, dependencies, components).

#### F3.2 Install
- scope 선택 다이얼로그 (user/project/local).
- userConfig 가 있는 플러그인은 옵션 입력 폼 자동 생성 (sensitive 키는 마스킹 + 키체인 안내).
- dependencies 미리 표시 + 사용자 동의 후 closure install.
- CLI bridge: `claude plugin install <name>@<market> --scope <s>`.

### F4. 사용자 자산 (User Assets) CRUD

> 이 영역은 CLI bridge 가 없으므로 **직접 파일 매니저 모드**.

#### F4.1 Skills (`~/.claude/skills/<name>/SKILL.md`)
- **Plugin-managed vs user-owned 구분**:
  - 플러그인 cache 디렉토리에서 watch 가 아니라, 플러그인 manifest 의 `skills` 필드 + `skills/` 표준 디렉토리 매핑 결과를 inverted index 로 보유.
  - 매핑된 디렉토리는 read-only 배지 + edit 차단.
  - 그 외 `~/.claude/skills/*` 는 user-owned.
- **CRUD**: create (template 포함), edit (외부 에디터 위임 또는 인앱 에디터), delete (확인 필요), rename.

#### F4.2 Agents (`~/.claude/agents/<name>.md`)
- 사용자 환경에는 현재 디렉토리 자체가 없음 → 첫 create 시 디렉토리 생성.
- **frontmatter 검증**: name, description, tools (선택), model (선택).
- 새 에이전트 생성 시 템플릿 제공.

#### F4.3 Commands (`~/.claude/commands/<name>.md`)
- 동일 패턴. frontmatter: argumentHint, allowedTools, model, description.

#### F4.4 Hooks (`settings.json` `hooks` 블록)
- 이벤트별 그룹 (PreToolUse, PostToolUse, SessionStart, Stop, UserPromptSubmit, Notification 등 — Claude Code 의 `HooksSchema` 미러).
- 각 hook entry: matcher (regex/literal), hooks[] (type=command, command, timeout?).
- CRUD UI + 미리보기 (실행될 명령어 그대로 표시).

### F5. Diagnostics

- **Plugin load errors**: `loadAllPlugins()` 결과의 errors[] 표시 (CLI bridge 가 `--json` 으로 노출하면 활용).
- **Orphaned cache**: `cache/` 폴더 중 `installed_plugins.json` 에 참조되지 않는 항목. 일괄 삭제 옵션.
- **Blocklist**: `blocklist.json` 표시.
- **Schema drift**: 본 매니저가 알고 있는 schema 버전과 실제 파일 버전 비교, 미지의 버전이면 read-only 모드.
- **Settings 충돌**: 같은 플러그인 ID 가 다중 scope 에 다른 값으로 선언된 경우 경고.

### F6. (옵션) CLI 모드

- 동일 core 라이브러리를 commander 기반 CLI 로도 노출.
- `pm list`, `pm install`, `pm enable`, `pm marketplace add`, `pm hook add` 등.
- 이는 Claude Code CLI 위에 얹는 **사용자 친화적 alias** 가 목표 (i.e. matcher 자동완성, 마켓 이름 fuzzy 검색).

---

## 5. 비기능 요구사항 (Non-Functional)

| 분류 | 요구사항 |
|---|---|
| **Performance** | 메뉴바 popover 첫 표시 < 200ms. 풀 윈도우 리스트 렌더 < 500ms (실측 26 플러그인). 앱 idle 시 메모리 < 50MB, CPU < 0.1%. |
| **Startup** | 로그인 후 메뉴바 아이콘 노출까지 < 1초. cold launch (앱 첫 실행) < 2초. |
| **Concurrency** | POSIX `flock(2)` + atomic rename 으로 settings.json / installed_plugins.json / known_marketplaces.json 락. Claude Code 의 `proper-lockfile` 규약과 호환되는 lockfile 이름/경로 사용. Lock 획득 timeout 10초, 실패 시 사용자 다이얼로그 (Retry / Cancel). |
| **Atomicity** | 단일 액션은 transaction. 실패 시 모든 파일 변경 롤백. |
| **Schema safety** | Claude Code schema 가 V3 로 올라가면 매니저는 read-only mode 로 자동 전환 + 경고. |
| **Privacy** | userConfig sensitive 값은 절대 매니저 로그/UI 평문 노출 안 함 (마스킹). Keychain 통합은 Claude Code 자체 메커니즘에 위임. |
| **Telemetry** | Claude Code 의 `tengu_plugin_*` 이벤트는 CLI bridge 가 자동 발행. 매니저 자체 telemetry 는 opt-in 만. |
| **i18n** | UI 1차 한국어, 메시지는 `Localizable.strings` 로 추상화 (영어 fallback). NSLocalizedString 사용. |
| **Accessibility** | VoiceOver 호환. SwiftUI `.accessibilityLabel`, `.accessibilityHint` 명시. 키보드 fully navigable. |
| **Platform** | **macOS 13.0 (Ventura) 이상**. macOS 13의 `MenuBarExtra` SwiftUI scene + `SMAppService.mainApp` 자동 시작 API 활용. Windows/Linux 비대상. |
| **Backward compat** | V1 `installed_plugins.json` 파일 만나면 read-only + V2 로 마이그레이션은 Claude Code 에 위임 (V1 감지 시 다이얼로그로 마이그레이션 안내). |
| **Distribution** | Developer ID Application 인증서 코드 사인 + Apple notarization + stapling. 배포 채널: GitHub Releases (dmg) + Homebrew Cask. Sparkle 2.x 로 in-app 자동 업데이트. |
| **Logging** | `~/Library/Logs/com.toby.ccplugin/cc-pm-YYYY-MM-DD.log`. 모든 CLI bridge 호출 (command, exit code, stderr) 기록. 7일 보관. sensitive 값 redact. |

### 5.1 보안 — 자식 프로세스 호출 규칙 (필수)

매니저는 모든 외부 명령 호출에서 다음을 준수한다:

- **금지**: 쉘 보간을 사용하는 형태(쉘 문자열 조립). 사용자 입력을 문자열로 이어 붙여 명령 라인을 만드는 모든 패턴은 차단. Swift `Process` 에서 `/bin/sh -c "..."`, `/bin/zsh -c "..."`, `launchPath` (deprecated) 사용 금지.
- **허용**: Swift Foundation `Process` 의 `executableURL: URL` (절대 경로) + `arguments: [String]` 패턴만 사용. 사용자 입력은 모두 `arguments` 배열로만 전달. argv 배열은 `posix_spawn(2)` 로 직접 전달되어 쉘 파서를 거치지 않음 → `;`, `|`, `$(...)` 메타문자 무력화.
- **권장 래퍼**: 본 매니저의 `PluginCore/Bridge/ProcessRunner.swift` 가 `async throws` 단일 진입점을 노출. 외부 명령 호출은 모두 이 래퍼만 통과. `Process()` 직접 사용은 lint 차단.
- **SwiftLint 규칙**:
  ```yaml
  custom_rules:
    no_shell_subprocess:
      regex: '/bin/(sh|bash|zsh).*-c'
      message: "Shell subprocess forbidden. Use ProcessRunner with explicit executable."
    no_legacy_launchpath:
      regex: '\.launchPath\s*='
      message: "Use executableURL instead of launchPath (deprecated)."
  ```
- **참고**: Claude Code 자체도 `src/utils/execFileNoThrow.ts` 에서 동일 규칙(execFile 기반)을 강제한다 — Swift `Process` + `executableURL` + `arguments[]` 가 등가물이다.

### 5.2 `claude` CLI 경로 해석 (PATH Resolution)

**문제**: macOS GUI 앱은 사용자 shell PATH (`~/.zshrc` 등)를 상속받지 않는다. `launchd`가 띄운 앱의 PATH는 `/usr/bin:/bin:/usr/sbin:/sbin` 정도로 제한적이라 Homebrew(`/opt/homebrew/bin`) 나 `~/.local/bin` 의 `claude` 를 찾지 못한다.

**해석 순서** (첫 성공 시 캐시):

1. **환경변수 `CC_PM_CLAUDE_BIN`** — 사용자가 명시한 절대 경로. 우선순위 최상.
2. **알려진 위치 스캔** — `[\"/opt/homebrew/bin\", \"/usr/local/bin\", \"~/.local/bin\", \"~/.npm-global/bin\"]` 순회.
3. **로그인 셸 위임** — 시작 시 1회 `Process(executable: /bin/zsh, arguments: [\"-l\", \"-c\", \"command -v claude\"])` 실행 후 stdout 추출. 결과는 `~/Library/Application Support/com.toby.ccplugin/preferences.plist` 에 캐시.
4. **사용자 선택** — 위 모두 실패 시 시작 시 다이얼로그 (NSOpenPanel) 로 `claude` 바이너리 직접 선택 요청. 선택 결과는 preferences 에 영구 저장.

**검증**: 해석된 경로로 `claude --version` 호출하여 exit code 0 확인. 실패 시 다음 후보로 진행.

**재해석 트리거**: 사용자가 환경설정에서 "Reset CLI path" 클릭, 또는 `claude --version` 호출이 ENOENT/ENOTFOUND 로 실패할 때.

---

## 6. 아키텍처 설계 (Architecture)

### 6.0 플랫폼 결정 (Platform Decision)

| 결정 | 채택 | 근거 |
|---|---|---|
| **OS** | macOS 13.0 (Ventura) 이상 | SwiftUI `MenuBarExtra` scene + `SMAppService` 자동 시작 API. Windows/Linux 비대상. |
| **앱 형태** | 메뉴바 상주 (`LSUIElement = YES`) | 사용자 요구. Dock 미노출, Cmd+Tab 미노출, 로그인 시 자동 시작. |
| **언어** | Swift 5.9+ (100% native, Option A) | 시작 속도 < 200ms, 메모리 < 50MB, Foundation `Process` 의 보안 모델이 PRD §5.1 과 정합. |
| **UI 프레임워크** | SwiftUI 1차 + AppKit 보조 | 메뉴바/popover/sheet 는 SwiftUI, NSStatusItem 같은 저수준은 AppKit interop. |
| **번들 형식** | Universal binary (arm64 + x86_64) | Apple Silicon 우선, Intel Mac 지원. |
| **배포** | Developer ID + Notarized dmg + Homebrew Cask | MAS 비대상 (외부 git 호출 + 임의 경로 R/W 가 심사 통과 어려움). |
| **자동 업데이트** | Sparkle 2.x + GitHub Releases appcast | EdDSA 서명, in-app silent update. |

> **거부된 대안**: Tauri (Rust + webview) 는 "native" 정의에 부합하지 않고 메뉴바 통합이 제한적. Electron 은 메모리 풋프린트 (>150MB) 가 메뉴바 앱 합격선 (<50MB) 초과. Node + XPC helper 는 번들 크기 + IPC 복잡도가 ROI 미달.

### 6.1 결정 사항 (Architecture Decisions)

> **v2.1 갱신 — M0 spike 결과 반영**: CLI 출력은 disk JSON 의 부분집합 → Direct file **read** 가 모든 view 구성에 필수 (1.5차 승격). Direct **mutation** 은 좁은 화이트리스트 (boolean flip + autoUpdate + hooks).

| 결정 | 채택 | 이유 |
|---|---|---|
| **Read 경로** | **CLI list + Direct file read 합성** | CLI `--json` 에 누락된 필드: `gitCommitSha`, `loadErrors`, marketplace `lastUpdated`/`autoUpdate`, plugin counts, manifest description/author/keywords. Disk read 없이는 PRD §F1 컴포넌트 카운트나 §F2 marketplace 화면 구성 불가. |
| **Mutation 경로 (1차 — CLI Bridge)** | install / uninstall / enable / disable / update / marketplace add / marketplace remove / marketplace update(refresh) | Dependency closure, git clone 옵션, telemetry 등 재구현 비용 ↑↑ |
| **Mutation 경로 (1.5차 — Direct settings.json patch)** | autoUpdate 토글, hooks CRUD, enable/disable boolean flip, marketplace add 후 ref/path/sparsePaths 백필 | CLI 가 노출하지 않는 영역 (M0 spike 검증). settings.json 은 Claude Code 가 proper-lockfile 사용 → 매니저도 호환 락 필요 (§10.4) |
| **Mutation 경로 (2차 — atomic rename only)** | installed_plugins.json 직접 쓰기 (비상 fallback) | Claude Code 가 락 미사용 + atomic rename 만 사용 → 매니저도 동일 패턴. 일반 흐름에선 CLI 가 처리하므로 거의 호출 안 됨. |
| **Mutation 경로 (예외 — UX 우선)** | enable/disable 의 boolean flip | CLI 호출 0.5–2초 vs 직접 < 10ms — 메뉴바 앱 UX 합격선과 직결. settings.json `enabledPlugins[id]` 만 패치. |
| **검증** | Swift `Codable` + Zod-equivalent constraints | Claude Code 의 zod 스키마를 Swift `Codable` + custom `init(from:)` 로 미러. PRD §11.1 drift test 는 golden fixture 라운드트립으로 시작. |
| **파일 락** | POSIX `flock(2)` + atomic rename | Claude Code 의 `proper-lockfile` lockfile 이름 규약과 호환되도록 `<file>.lock` 패턴 사용. |
| **자식 프로세스** | Swift `Process` + `executableURL` + `arguments[]` | 쉘 미사용. `posix_spawn(2)` 직접 위임으로 명령 인젝션 차단. PRD §5.1 강제. |
| **HTTP/Networking** | `URLSession` + `async/await` | Sparkle appcast 다운로드, marketplace.json HTTP source. |
| **JSON 파싱** | `JSONDecoder` / `JSONEncoder` + Codable | zod runtime validation 등가물. unknown key 는 `passthrough` 패턴 (`AnyCodable` 보조 타입) 으로 보존. |
| **상태 관리** | `@Observable` (macOS 14+) 또는 `ObservableObject` (macOS 13) | macOS 13 호환을 위해 `ObservableObject` 1차, 향후 minimum bump 시 `@Observable` 로 전환. |
| **파일 변경 감지** | FSEventStream (Carbon API) | `~/.claude/` 트리 단위 watch, `kFSEventStreamCreateFlagIgnoreSelf` 로 자기 쓰기 무한 루프 방지, 500ms latency. |
| **CLI (옵션, headless 모드)** | Swift Argument Parser | `cc-pm list`, `cc-pm install` 등. SwiftUI 의존 없이 PluginCore 만 사용. |
| **로깅** | `os.Logger` (Unified Logging) + 파일 mirror | Console.app 노출 + `~/Library/Logs/com.toby.ccplugin/` 에 일별 파일 |

### 6.2 패키지 레이아웃 (Xcode Workspace + Swift Package)

```
ccplugin/                                       # 새 프로젝트 루트
├── ccplugin.xcworkspace/                       # Xcode workspace (App + Package)
├── App/                                        # macOS 메뉴바 SwiftUI 앱
│   ├── ccplugin.xcodeproj/
│   ├── ccpluginApp.swift                       # @main, MenuBarExtra scene
│   ├── Info.plist                              # LSUIElement = YES
│   ├── ccplugin.entitlements                   # Hardened Runtime, sandbox OFF
│   ├── MenuBar/
│   │   ├── StatusItemController.swift          # NSStatusItem (필요 시 AppKit interop)
│   │   ├── PopoverView.swift                   # 빠른 상태 320×400
│   │   └── MainWindowController.swift          # 풀 매니저 NSWindow 1024×700
│   ├── Views/
│   │   ├── InstalledTab.swift
│   │   ├── MarketplacesTab.swift
│   │   ├── BrowseTab.swift
│   │   ├── UserAssetsTab.swift
│   │   ├── HooksTab.swift
│   │   ├── DiagnosticsTab.swift
│   │   ├── PreferencesView.swift               # CLI path, autostart, 백업 설정
│   │   └── Dialogs/
│   │       ├── InstallDialog.swift             # scope + userConfig form
│   │       ├── AddMarketplaceDialog.swift
│   │       └── ConfirmDialog.swift
│   ├── ViewModels/
│   │   ├── PluginInventoryViewModel.swift
│   │   ├── MarketplaceViewModel.swift
│   │   └── DiagnosticsViewModel.swift
│   ├── Services/
│   │   ├── AutoLaunchService.swift             # SMAppService 래퍼
│   │   ├── ReloadHintService.swift             # 실행 중 Claude 세션 감지 (pgrep)
│   │   └── SparkleUpdaterController.swift      # in-app 업데이트
│   ├── Resources/
│   │   ├── Assets.xcassets                     # 메뉴바 아이콘 (template image)
│   │   └── Localizable.strings                 # ko, en
│   └── ccpluginTests/
│
├── Packages/
│   └── PluginCore/                             # Swift Package (UI 무의존)
│       ├── Package.swift
│       ├── Sources/PluginCore/
│       │   ├── Schemas/                        # Claude Code zod 미러 → Swift Codable
│       │   │   ├── PluginManifest.swift        # PluginManifestSchema mirror
│       │   │   ├── PluginSource.swift          # PluginSourceSchema (github/git/npm/...)
│       │   │   ├── MarketplaceSource.swift     # MarketplaceSourceSchema
│       │   │   ├── InstalledPluginsV2.swift    # InstalledPluginsFileSchemaV2
│       │   │   ├── KnownMarketplaces.swift
│       │   │   ├── HooksSchema.swift           # settings.json hooks 블록
│       │   │   ├── ManagerSettingsSubset.swift # 우리가 만지는 settings.json 영역
│       │   │   └── AnyCodable.swift            # passthrough unknown keys
│       │   ├── IDs/
│       │   │   ├── PluginID.swift              # 정규식 검증 + parse/build
│       │   │   └── MarketplaceNameGuard.swift  # BLOCKED_OFFICIAL_PATTERN, ALLOWED_OFFICIAL_NAMES
│       │   ├── Paths/
│       │   │   ├── ClaudePaths.swift           # CLAUDE_CONFIG_DIR override 처리
│       │   │   └── ScopePaths.swift            # 4-scope cascade
│       │   ├── Locking/
│       │   │   └── FileLock.swift              # flock(LOCK_EX|LOCK_NB) 래퍼
│       │   ├── Watching/
│       │   │   └── FSEventsWatcher.swift       # FSEventStream 래퍼
│       │   ├── Readers/
│       │   │   ├── SettingsReader.swift        # 4-scope cascade
│       │   │   ├── InstalledReader.swift
│       │   │   ├── MarketplaceReader.swift
│       │   │   ├── PluginManifestReader.swift  # cache/.../plugin.json
│       │   │   └── UserAssetReader.swift
│       │   ├── Writers/
│       │   │   ├── SettingsWriter.swift        # atomic rename + flock
│       │   │   ├── BackupService.swift         # mutation 직전 백업
│       │   │   └── UserAssetWriter.swift
│       │   ├── Bridge/
│       │   │   ├── ProcessRunner.swift         # Foundation.Process 단일 진입점
│       │   │   ├── ClaudeCLIPathResolver.swift # PRD §5.2 fallback chain
│       │   │   ├── ClaudeCLI.swift             # claude 호출 + JSON 파싱
│       │   │   └── Operations/
│       │   │       ├── InstallOperation.swift
│       │   │       ├── UninstallOperation.swift
│       │   │       ├── EnableOperation.swift
│       │   │       ├── DisableOperation.swift
│       │   │       ├── UpdateOperation.swift
│       │   │       └── MarketplaceOperations.swift
│       │   ├── Domain/                         # UI 에 흘릴 view model
│       │   │   ├── PluginInventoryItem.swift
│       │   │   ├── MarketplaceInventoryItem.swift
│       │   │   └── UserAssetItem.swift
│       │   ├── Diagnostics/
│       │   │   ├── OrphanedCacheDetector.swift
│       │   │   ├── SchemaDriftDetector.swift
│       │   │   └── ConflictDetector.swift
│       │   ├── Logging/
│       │   │   └── Log.swift                   # os.Logger + 파일 mirror
│       │   └── PluginCore.swift                # public facade
│       └── Tests/PluginCoreTests/
│           ├── Fixtures/                       # 본인 ~/.claude snapshot
│           ├── SchemaRoundtripTests.swift      # PRD §11.1 drift test
│           ├── ReaderTests.swift
│           ├── WriterAtomicityTests.swift
│           ├── ProcessRunnerSecurityTests.swift # 쉘 인젝션 시도 거절 검증
│           └── PluginIDTests.swift
│
├── Headless/                                   # 옵션: CLI 헤드리스 모드 (PRD §F6)
│   └── Sources/cc-pm/
│       └── main.swift                          # Swift Argument Parser
│
├── Scripts/
│   ├── notarize.sh                             # xcrun notarytool submit
│   ├── build-dmg.sh                            # create-dmg
│   ├── sign.sh                                 # codesign --options runtime
│   ├── sync-claude-fixtures.sh                 # vendor/claude-code 핀 갱신
│   └── update-appcast.sh                       # Sparkle appcast.xml 갱신
│
├── vendor/
│   └── claude-code/                            # git submodule (PRD §11.1 reference)
│
└── docs/
    ├── architecture.md
    ├── data-model.md
    ├── distribution.md                         # 공증/배포 절차
    └── reference-from-claude-code.md
```

### 6.3 모듈 책임 경계

| 모듈 | 의존 가능 | 의존 금지 |
|---|---|---|
| `PluginCore` (Swift Package) | Foundation, System, Darwin (POSIX), os.log | SwiftUI, AppKit, UIKit |
| `App` (macOS app target) | PluginCore, SwiftUI, AppKit, Sparkle, ServiceManagement | – |
| `Headless` (CLI target) | PluginCore, ArgumentParser | SwiftUI, AppKit |

> **핵심 원칙**: PluginCore 는 **순수 Foundation only** — UI 프레임워크 의존이 들어오는 순간 단위 테스트 + headless CLI 재사용이 깨진다. PRD v1.0 의 `core` ↔ `tui` 경계 원칙을 그대로 계승, 이름만 Swift화.

### 6.4 단일 mutation 의 라이프사이클 (예: install)

```
[메뉴바 클릭 → Popover → "Open Full Manager" → MainWindow → Browse 탭]
        ↓
[InstallDialog (SwiftUI sheet): scope 선택, userConfig 입력, 의존성 closure 미리보기]
        ↓
[PluginInventoryViewModel.install(id:scope:userConfig:)]
        ↓
[PluginCore/Bridge/Operations/InstallOperation.swift]
        ↓
[BackupService.backup(.installedPlugins, .settings)]   # mutation 직전
        ↓
[ClaudeCLI.run(["plugin","install",id,"--scope",s])]
   → ProcessRunner (Process + executableURL + arguments[])
   → stdout 라인 stream → AsyncStream<String> → UI 진행률
        ↓
[exit code 0 → 성공 / 그 외 → 에러 다이얼로그 + 백업 복원 옵션]
        ↓
[InstalledReader.reload()] (FSEventsWatcher 가 이미 트리거할 수 있지만 명시적으로 한 번 더)
        ↓
[ViewModel @Published 갱신 → SwiftUI 자동 리렌더]
        ↓
[UI: Installed 탭으로 이동 + 메뉴바 아이콘 옆 "● 1 변경 보류" 배지 + "/reload-plugins 실행 필요" 배너]
        ↓
[ReloadHintService.detectRunningClaudeSessions()] → "Claude Code 2개 실행 중" 안내
```

### 6.5 Schema Drift 감지

PRD §11.1 의 drift test 를 Swift 환경에서 다음 2단계로 구현:

**1단계 (M1 시작 — Golden Fixture 라운드트립)**:
- `vendor/claude-code` 서브모듈에 Claude Code 를 commit-pinned 로 vendor.
- 본인 환경의 `~/.claude/plugins/{installed_plugins,known_marketplaces,blocklist}.json` + 각 marketplace 의 `marketplace.json` snapshot 을 `Tests/Fixtures/` 에 commit.
- `XCTest` 에서 `JSONDecoder().decode(InstalledPluginsFileV2.self, from: fixture)` 라운드트립 + 인코드 후 byte-equivalent 검증 (key 누락 여부).
- 실패 시 → 사람이 fixture 를 갱신 + Swift Codable 미러 동기화.

**2단계 (M2 이후 — JSON Schema export 비교, 옵션)**:
- 빌드 시 Node 스크립트 (`Scripts/sync-claude-fixtures.sh`) 가 vendor 의 zod 스키마를 `zodToJsonSchema()` 로 export.
- Swift Codable 스키마는 별도 `JSONSchemaBuilder` (또는 수동 .json) 로 export.
- `diff` 결과 비어있지 않으면 CI 실패.

> **수동 동기화 명령**: `./Scripts/sync-claude-fixtures.sh` 가 vendor 핀을 갱신 + fixture 를 `~/.claude` 에서 재캡처.

### 6.6 메뉴바 UX 패턴 (Menubar UX)

#### 6.6.1 메뉴바 아이콘

- **이미지**: SF Symbol `puzzlepiece.extension` 의 template (단색, 시스템 dark/light 자동 적응).
- **상태 배지**:
  | 상태 | 표시 |
  |---|---|
  | 정상 | 아이콘만 |
  | 변경 보류 (reload 필요) | 아이콘 + 노란색 dot |
  | 에러 (load error / orphaned cache) | 아이콘 + 빨간색 dot |
  | 업데이트 사용 가능 | 아이콘 + 파란색 dot |
- **숫자 배지** (옵션, Preferences 토글): 활성 플러그인 수.

#### 6.6.2 클릭 동작

```
[메뉴바 아이콘 클릭]
        ↓
[NSPopover (SwiftUI) — 320×400]
  • 헤더: "26 enabled · 3 errors · 1 update"
  • 빠른 액션 버튼: [Refresh All] [Reload Hint] [Open Full Manager]
  • 최근 변경 5개 (mtime 기준)
  • 하단: 환경설정 / 종료
        ↓
[Popover 내부 "Open Full Manager" 클릭 → NSWindow 활성]
        ↓
[NSWindow (SwiftUI 1024×700) — Tabs:
  Installed | Marketplaces | Browse | User Assets | Hooks | Diagnostics]
```

- **NSWindow lifecycle**: 닫아도 앱은 메뉴바에 잔류. `NSApp.setActivationPolicy(.accessory)` 로 Dock 미노출 유지.
- **단축키**:
  | Key | Action |
  |---|---|
  | ⌘ + , | Preferences |
  | ⌘ + R | 현재 탭 새로고침 |
  | ⌘ + 1–6 | 탭 전환 |
  | ⌘ + W | 풀 매니저 윈도우 닫기 (앱은 종료 안 됨) |
  | ⌘ + Q | 앱 완전 종료 |
- **메뉴바 우클릭**: 컨텍스트 메뉴 (Refresh All / Open Manager / Preferences / Quit).

#### 6.6.3 자동 시작

- 첫 실행 시 다이얼로그: "로그인 시 자동 시작하시겠습니까?" → `SMAppService.mainApp.register()`.
- Preferences 에서 ON/OFF 토글.

#### 6.6.4 알림 (Notifications)

- `UserNotifications` framework 사용 (`UNUserNotificationCenter`).
- 트리거:
  - Marketplace refresh 결과 (옵션)
  - Update 사용 가능
  - 백그라운드 mutation 실패 (autoUpdate 결과)
- 첫 실행 시 권한 요청, Preferences 에서 OFF 가능.

#### 6.6.5 "Reload Hint" UX 강화

PRD §1.2 의 Layer 3 한계로 `/reload-plugins` 안내가 핵심. 다음 보강:

- 실행 중 Claude 프로세스 감지: `pgrep -f 'node.*claude'` → 매니저 작동 시 1회 + 변경 mutation 시.
- 감지된 경우 popover 헤더에 "● Claude Code 2개 실행 중 — `/reload-plugins` 권장" 강조 표시.
- "Copy `/reload-plugins`" 버튼 제공 (클립보드 복사) — 사용자가 즉시 paste 가능.

---

## 7. 데이터 모델 (Data Model — Swift Codable Mirror)

> Claude Code 의 zod 스키마를 Swift Codable 로 미러링. 모든 타입은 `PluginCore/Schemas/` 모듈에 위치. 모르는 키 보존을 위해 `additionalKeys: [String: AnyCodable]` 패스스루 패턴 사용.

### 7.1 InstalledPluginsFile V2 (mirror)

```swift
// PluginCore/Schemas/InstalledPluginsV2.swift
public enum PluginScope: String, Codable, CaseIterable, Sendable {
    case managed, user, project, local
}

public struct PluginInstallationEntry: Codable, Sendable, Equatable {
    public let scope: PluginScope
    public let projectPath: String?       // project/local scope 시 필수
    public let installPath: String        // 절대 경로
    public let version: String?
    public let installedAt: Date?         // ISO 8601, custom DateDecodingStrategy
    public let lastUpdated: Date?
    public let gitCommitSha: String?
}

public struct InstalledPluginsFileV2: Codable, Sendable {
    public let version: Int               // == 2 검증은 init(from:) 에서
    public let plugins: [String: [PluginInstallationEntry]]  // key = "name@market"

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        guard v == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "Unsupported installed_plugins.json version \(v) — manager enters read-only mode")
        }
        self.version = v
        self.plugins = try c.decode([String: [PluginInstallationEntry]].self, forKey: .plugins)
    }
}
```

### 7.2 KnownMarketplacesFile (mirror)

```swift
// PluginCore/Schemas/KnownMarketplaces.swift
public struct KnownMarketplace: Codable, Sendable {
    public let source: MarketplaceSource     // §7.6
    public let installLocation: String
    public let lastUpdated: Date
    public let autoUpdate: Bool?
}

// 파일 자체가 [name: KnownMarketplace] 사전형 → typealias 로 충분
public typealias KnownMarketplacesFile = [String: KnownMarketplace]
```

### 7.3 우리 매니저가 다루는 settings.json subset

```swift
// PluginCore/Schemas/ManagerSettingsSubset.swift
public struct ExtraKnownMarketplaceEntry: Codable, Sendable {
    public let source: MarketplaceSource
    public let autoUpdate: Bool?
}

public struct ManagerSettingsSubset: Codable, Sendable {
    public var enabledPlugins: [String: Bool]?
    public var extraKnownMarketplaces: [String: ExtraKnownMarketplaceEntry]?
    public var hooks: HooksConfig?
    /// 우리가 모르는 모든 키. 쓰기 시 그대로 흘려보냄 (passthrough).
    public var additionalKeys: [String: AnyCodable] = [:]
    // init(from:) / encode(to:) 에서 known + additionalKeys 합쳐 직렬화.
}
```

### 7.4 도메인 모델 (UI 에 흘릴 합쳐진 view)

```swift
// PluginCore/Domain/PluginInventoryItem.swift
public struct ComponentCounts: Sendable, Equatable {
    public let commands: Int
    public let agents: Int
    public let skills: Int
    public let hooks: Int
    public let mcpServers: Int
    public let lspServers: Int
}

public struct PluginInventoryItem: Identifiable, Sendable, Equatable {
    public let id: String                                       // "name@market"
    public let name: String
    public let marketplace: String
    public let installations: [PluginInstallationEntry]         // V2 multi-scope
    public let enabledByScope: [PluginScope: Bool]
    public let manifest: PluginManifest?                        // cache 에서 읽기
    public let components: ComponentCounts
    public let loadErrors: [String]                             // CLI --json 의 errors[]
    public let isOfficial: Bool
    public let isManaged: Bool
    public let source: PluginSource?                            // 마켓 entry 에서
}

public struct MarketplaceInventoryItem: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let source: MarketplaceSource
    public let installLocation: String
    public let lastUpdated: Date
    public let autoUpdate: Bool
    public let declaredIn: SettingsOrigin                       // userSettings | projectSettings | localSettings | seed
    public let pluginCount: Int
    public let installedFromHere: Int
    public let isOfficial: Bool
    public let isReadOnly: Bool                                 // seed/managed
}

public enum SettingsOrigin: String, Sendable, Codable {
    case userSettings, projectSettings, localSettings, seed
}
```

### 7.5 Plugin 식별자 가드 (정규식 + 사칭 차단)

```swift
// PluginCore/IDs/PluginID.swift
public enum PluginID {
    public static let pattern = #/^[a-z0-9][-a-z0-9._]*@[a-z0-9][-a-z0-9._]*$/#

    public struct Parsed: Sendable, Equatable {
        public let name: String
        public let marketplace: String?
    }

    public static func validate(_ s: String) -> Bool {
        s.wholeMatch(of: pattern) != nil
    }

    public static func parse(_ s: String) -> Parsed {
        guard let at = s.firstIndex(of: "@") else { return .init(name: s, marketplace: nil) }
        return .init(name: String(s[..<at]), marketplace: String(s[s.index(after: at)...]))
    }
}

// PluginCore/IDs/MarketplaceNameGuard.swift
public enum MarketplaceNameGuard {
    /// 공식 마켓 사칭 차단 (Claude Code schemas.ts:71 미러)
    public static let blockedOfficialPattern = #/(?:official[^a-z0-9]*(anthropic|claude)|(?:anthropic|claude)[^a-z0-9]*official|^(?:anthropic|claude)[^a-z0-9]*(marketplace|plugins|official))/#.ignoresCase()

    /// 공식 예약 이름 화이트리스트 (Claude Code schemas.ts:19-28)
    public static let allowedOfficialNames: Set<String> = [
        "claude-code-marketplace", "claude-code-plugins", "claude-plugins-official",
        "anthropic-marketplace", "anthropic-plugins", "agent-skills",
        "life-sciences", "knowledge-work-plugins",
    ]

    public static func isBlocked(name: String) -> Bool {
        // 비ASCII 거절 (homograph)
        guard name.allSatisfy({ $0.isASCII }) else { return true }
        if allowedOfficialNames.contains(name) { return false }
        return name.firstMatch(of: blockedOfficialPattern) != nil
    }
}
```

### 7.6 PluginSource / MarketplaceSource enum (mirror)

```swift
// PluginCore/Schemas/PluginSource.swift — discriminator: source 필드
public enum PluginSource: Codable, Sendable, Equatable {
    case relativePath(String)                                       // "./..."
    case github(repo: String, ref: String?, sha: String?)
    case gitSubdir(url: String, path: String, ref: String?, sha: String?)
    case url(url: String, ref: String?, sha: String?)
    case npm(package: String, version: String?, registry: String?)
    case pip(package: String, version: String?, registry: String?)
    // Codable 수동 구현 (discriminator 분기)
}

// PluginCore/Schemas/MarketplaceSource.swift
public enum MarketplaceSource: Codable, Sendable, Equatable {
    case url(url: String, headers: [String: String]?)
    case github(repo: String, ref: String?, path: String?, sparsePaths: [String]?)
    case git(url: String, ref: String?, path: String?, sparsePaths: [String]?)
    case npm(package: String)
    case file(path: String)
    case directory(path: String)
    case hostPattern(String)
    case pathPattern(String)
    case settings(name: String, plugins: [SettingsPluginEntry], owner: String?)
}
```

---

## 8. 인터페이스 / API 계약 (Module Contracts — Swift)

> 모든 비동기 인터페이스는 `async throws`. 구조화된 동시성 (`Task`, `AsyncStream`) 사용. UI 는 ViewModel 을 거쳐 호출하며 `MainActor` 격리.

### 8.1 Readers

```swift
// PluginCore/Readers/InstalledReader.swift
public protocol InstalledReader: Sendable {
    func load() async throws -> InstalledPluginsFileV2
}

// PluginCore/Readers/MarketplaceReader.swift
public protocol MarketplaceReader: Sendable {
    func loadKnown() async throws -> KnownMarketplacesFile
    func loadMarketplaceManifest(name: String) async throws -> PluginMarketplace?
    func listPlugins(in marketplaceName: String) async throws -> [PluginMarketplaceEntry]
}

// PluginCore/Readers/UserAssetReader.swift
public enum AssetClassification: Sendable { case pluginManaged, userOwned, unknown }

public protocol UserAssetReader: Sendable {
    func listSkills() async throws -> [UserSkillRecord]
    func listAgents() async throws -> [UserAgentRecord]
    func listCommands() async throws -> [UserCommandRecord]
    func classifyPath(_ absolutePath: String) async -> AssetClassification
}

// PluginCore/Watching/FSEventsWatcher.swift — 모든 reader 가 옵션으로 watch 가능
public final class FSEventsWatcher {
    public init(paths: [URL], latency: TimeInterval = 0.5)
    public func start(onChange: @Sendable @escaping (Set<URL>) -> Void)
    public func stop()
}
```

### 8.2 Bridge (CLI 위임)

```swift
// PluginCore/Bridge/ProcessRunner.swift
// 단일 진입점. 쉘 미사용. 사용자 입력은 arguments[] 배열로만.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public protocol ProcessRunner: Sendable {
    func run(executable: URL,
             arguments: [String],
             environment: [String: String]?,
             timeout: Duration) async throws -> ProcessResult

    /// 진행률 stream — stdout 라인 단위
    func runStream(executable: URL,
                   arguments: [String],
                   environment: [String: String]?,
                   timeout: Duration) -> AsyncThrowingStream<String, Error>
}

// PluginCore/Bridge/ClaudeCLI.swift
public protocol ClaudeCLI: Sendable {
    /// 해석된 claude 바이너리 경로 (PRD §5.2).
    var executable: URL { get async throws }

    func run(arguments: [String], json: Bool) async throws -> ProcessResult
    func runStream(arguments: [String]) -> AsyncThrowingStream<String, Error>
}

// PluginCore/Bridge/Operations/InstallOperation.swift
public struct InstallRequest: Sendable {
    public let pluginID: String                       // "name@market"
    public let scope: PluginScope                     // user | project | local (managed 차단)
    public let userConfig: [String: String]?          // env 또는 stdin
}

public struct OperationOutcome: Sendable {
    public let ok: Bool
    public let message: String
    public let stderr: String?
}

public protocol InstallOperation: Sendable {
    func install(_ request: InstallRequest,
                 onProgress: @Sendable @escaping (String) -> Void) async throws -> OperationOutcome
}

// 동일 패턴: UninstallOperation, EnableOperation, DisableOperation,
// UpdateOperation, MarketplaceAddOperation, MarketplaceRemoveOperation,
// MarketplaceRefreshOperation, MarketplaceSetAutoUpdateOperation
```

### 8.3 Writers (CLI bridge 가 못 다루는 영역)

```swift
// PluginCore/Writers/SettingsWriter.swift
public enum HookEvent: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
    case userPromptSubmit = "UserPromptSubmit"
    case notification = "Notification"
}

public struct HookEntry: Codable, Sendable, Equatable {
    public let type: String                           // "command"
    public let command: String
    public let timeout: Int?
}

public protocol SettingsWriter: Sendable {
    func setHook(event: HookEvent, matcher: String?, entry: HookEntry,
                 scope: PluginScope) async throws
    func removeHook(event: HookEvent, matcher: String?, index: Int,
                    scope: PluginScope) async throws

    /// 비상 fallback (CLI 부재 시) — 단순 boolean flip 은 UX 상 직접 처리도 허용
    func setEnabledPlugin(pluginID: String, enabled: Bool,
                          scope: PluginScope) async throws
}
```

### 8.4 Diagnostics

```swift
// PluginCore/Diagnostics/Diagnostic.swift
public enum Diagnostic: Sendable, Equatable {
    case orphanedCache(path: String, sizeBytes: Int64)
    case schemaDrift(file: String, expectedVersion: Int, gotVersion: Int)
    case conflictingScope(pluginID: String, scopes: [PluginScope])
    case loadError(pluginID: String, message: String)
    case blockedByPolicy(pluginID: String)
}

public protocol DiagnosticsRunner: Sendable {
    func run() async throws -> [Diagnostic]
}
```

### 8.5 Locking

```swift
// PluginCore/Locking/FileLock.swift
public actor FileLock {
    public enum AcquireError: Error { case timeout, busy, ioError(Error) }

    /// flock(LOCK_EX | LOCK_NB) 시도, timeout 까지 backoff retry.
    public func acquire(at lockfileURL: URL,
                        timeout: Duration = .seconds(10)) async throws
    public func release() async
}
```

---

## 9. UI 사양 (UI Specification — macOS Menubar Native)

> 본 섹션은 메뉴바 popover (320×400) + 메인 윈도우 (1024×700) 두 창의 SwiftUI 사양을 기술한다. 모든 wireframe 은 기능적 의도 표현용이며 최종 비주얼은 디자인 시스템 단계에서 확정.

### 9.1 메뉴바 아이콘 (Status Item)

- **이미지**: SF Symbol `puzzlepiece.extension` template image, 16×16pt.
- **상태 dot 오버레이** (overlay 위치: 아이콘 우상단):
  | 상태 | dot 색 | 우선순위 |
  |---|---|---|
  | 에러 (load error / orphaned cache) | 🔴 빨강 | 1 |
  | 변경 보류 (reload 필요) | 🟡 노랑 | 2 |
  | 업데이트 사용 가능 | 🔵 파랑 | 3 |
  | 정상 | 없음 | – |
- **Tooltip** (hover): "Claude Plugin Manager — 26 enabled · 1 update"

### 9.2 Popover (320 × 400 — 좌클릭 시)

```
╔════════════════════════════════════════╗
║  Claude Plugin Manager           ⚙ … ║   ← 우상단: Preferences, Quit menu
║                                        ║
║  📦 26 enabled · ⚠ 3 errors · ⬆ 1     ║   ← 헤더 status line
║                                        ║
║  ┌───────────────────────────────────┐ ║
║  │ ● Claude Code 2개 실행 중           │ ║   ← Reload Hint (PRD §6.6.5)
║  │   변경 반영 필요 · /reload-plugins  │ ║
║  │                       [Copy cmd]  │ ║
║  └───────────────────────────────────┘ ║
║                                        ║
║  Quick actions                         ║
║   [↻ Refresh All]  [⚡ Update All]      ║
║                                        ║
║  Recent changes                        ║
║   ✓ enable feature-dev    2분 전        ║
║   ⬆ update toby-essentials 5분 전       ║
║   + add harness-marketplace 1시간 전    ║
║                                        ║
║  ─────────────────────────────────     ║
║  [Open Full Manager]                   ║   ← Cmd+Return 으로도 열림
╚════════════════════════════════════════╝
```

- **닫힘 동작**: ESC, popover 외부 클릭, 메뉴바 아이콘 재클릭.
- **우클릭 메뉴**: Open Full Manager / Refresh All / Preferences / Check for Updates / Quit.

### 9.3 메인 윈도우 (1024 × 700)

```
┌──────────────────────────────────────────────────────────────────┐
│ Claude Plugin Manager           ~/.claude    [⚙ Preferences]    │ ← Toolbar
├──────────────────────────────────────────────────────────────────┤
│ ┌─ Sidebar 220 ─┐  ┌─ Main 804 ────────────────────────────────┐ │
│ │ ▸ Installed 26│  │                                           │ │
│ │ ▸ Marketplaces│  │   <selected tab content>                  │ │
│ │ ▸ Browse      │  │                                           │ │
│ │ ▸ User Assets │  │                                           │ │
│ │ ▸ Hooks       │  │                                           │ │
│ │ ▸ Diagnostics │  │                                           │ │
│ └───────────────┘  └───────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────┤
│ ⚠ 3 changes pending — run /reload-plugins in Claude Code   [Copy]│ ← Status bar
└──────────────────────────────────────────────────────────────────┘
```

- **Sidebar**: SwiftUI `NavigationSplitView`. 좌측 리스트, 우측 detail.
- **Toolbar**: macOS native toolbar. 검색 필드 (⌘F focus).
- **Status bar (하단)**: 변경 보류 / Claude 세션 감지 결과. 클릭 시 Diagnostics 탭으로.

### 9.4 단축키 (메인 윈도우)

| Key | Action |
|---|---|
| ⌘ + 1–6 | 탭 전환 (Installed/Marketplaces/Browse/UserAssets/Hooks/Diagnostics) |
| ⌘ + F | 현재 탭 검색 필드 focus |
| ⌘ + R | 현재 탭 새로고침 |
| ⌘ + N | 현재 탭의 "신규 생성" (Marketplace 탭 = Add Marketplace, Hooks 탭 = Add Hook 등) |
| ⌘ + , | Preferences |
| ⌘ + W | 메인 윈도우 닫기 (앱은 메뉴바 잔류) |
| ⌘ + Q | 앱 완전 종료 |
| ⌘ + ⇧ + R | Refresh All Marketplaces |

### 9.5 Installed 탭

**좌측 리스트** (List with multi-select):
- 컬럼 (SwiftUI `Table`): Status (✓/✗/⚠), Name, Marketplace, Scope, Version, Source type, Last updated.
- 필터 chip (toolbar): Scope (user/project/local), Marketplace, Enabled-only, Has-errors-only.
- 검색: 이름 + 제공 commands/agents/skills 풀텍스트.

**우측 Detail pane**:
- Manifest 정보 (name, description, author, repository, homepage, keywords).
- 컴포넌트 카운트 — 클릭 시 펼쳐서 개별 commands/agents/skills 리스트 표시.
- Dependencies 트리.
- 설치 정보: scope, version, gitCommitSha, installedAt, lastUpdated.
- 액션 버튼: Enable / Disable / Update / Uninstall / Open in Finder / Show Manifest.
- 멀티선택 시 detail pane 가 bulk action 폼으로 전환.

### 9.6 Marketplaces 탭

- **Table** 컬럼: Name, Source (icon + URL), Auto-update toggle, Last updated, Plugin count, Installed count, Read-only badge (seed/managed).
- **Toolbar 버튼**: Add (⌘N), Refresh selected, Refresh All (⌘⇧R), Browse selected, Remove.
- **Auto-update** 은 cell 내 직접 SwiftUI `Toggle` (즉시 반영, 옵션-잠금 시 disabled).

### 9.7 Add Marketplace Sheet

SwiftUI `.sheet(...)` modal. 320×420.

```
┌─ Add Marketplace ──────────────────────────────────────┐
│                                                        │
│  Source type     [GitHub  ▼]  ← Picker: GitHub /       │
│                                Git URL / URL / File /  │
│                                Directory / NPM         │
│                                                        │
│  Name            [________________________]            │
│                  (kebab-case, ASCII only)              │
│                                                        │
│  GitHub repo     [owner/repo___________]               │
│  Ref (optional)  [________________________]            │
│  Path (optional) [________________________]            │
│  Sparse paths    [________________________]            │
│                  (one per line)                        │
│                                                        │
│  ☐ Enable autoUpdate                                   │
│  Scope           [User  ▼]                             │
│                                                        │
│  ──────────────────────────────────────────────         │
│  ⚠ Validation result will appear here                  │
│                                                        │
│              [ Cancel ]   [ Validate ]   [ Add ]       │
└────────────────────────────────────────────────────────┘
```

- 클라이언트 사이드 검증: `MarketplaceNameGuard.isBlocked(name:)` (PRD §7.5), ASCII-only, allowed-official whitelist 출처 검증.
- "Validate" 버튼 → `claude plugin marketplace add --dry-run` (지원 여부 확인 후 fallback).

### 9.8 Browse → Install Flow

1. Marketplaces 탭 → 마켓 선택 → "Browse" 버튼 → Browse 탭으로 자동 전환 (선택 마켓 pre-filter).
2. **Browse Table**: name, description, category, tags, Install state badge (Installed / Not installed / Update available), install count.
3. 플러그인 행 클릭 → 우측 detail pane: manifest preview, dependencies tree, source type, README excerpt (있으면).
4. "Install" 버튼 → **InstallDialog** sheet:

```
┌─ Install: oh-my-claudecode@omc ────────────────────────┐
│                                                        │
│  Scope             [User  ▼]   ⓘ project/local 은 cwd  │
│                                필요                    │
│                                                        │
│  Dependencies (closure)                                │
│   ✓ already installed: foundation@omc                  │
│   ⊕ will install: helper@omc (1.0.2)                  │
│                                                        │
│  User configuration                                    │
│   API key (sensitive)  [••••••••__________]  [Show]   │
│   Default model        [opus  ▼]                       │
│                                                        │
│  ──────────────────────────────────────────────         │
│              [ Cancel ]              [ Install ]       │
└────────────────────────────────────────────────────────┘
```

5. Install 클릭 → progress sheet (stdout 라인 stream 표시) → 완료 시 Installed 탭으로 자동 이동 + 메뉴바 dot 갱신.

### 9.9 User Assets 탭 (Skills / Agents / Commands)

- 3-segment picker 상단 (Skills / Agents / Commands).
- **Table** 컬럼: Name, Type (user-owned / plugin-managed), Path, Last modified.
- **plugin-managed** 행은 회색 + 🔒 아이콘 + edit/delete 비활성. 호버 시 "Owned by `<plugin@market>`" tooltip.
- **Toolbar**: New (⌘N) — 템플릿 sheet 로 SKILL.md / agent .md / command .md 생성.
- 인앱 에디터 (간이 monospace) + "Open in External Editor" 버튼 (`NSWorkspace.shared.open` → 사용자 기본 .md 핸들러).

### 9.10 Hooks 탭

```
┌─ Hooks (settings.json — user scope) ───────────────────────────┐
│                                                                │
│  Scope:  [User  ▼]   ⓘ project/local 은 cwd 진입 시 노출       │
│                                                                │
│  ▾ SessionStart  (1)                                           │
│    ┌──────────────────────────────────────────────────────┐   │
│    │ matcher: (none)                                      │   │
│    │ command: /Users/tobylee/.claude/skills/gstack/bin... │   │
│    │ timeout: 60s                              [Edit] [✕] │   │
│    └──────────────────────────────────────────────────────┘   │
│                                                                │
│  ▸ PreToolUse  (0)                                             │
│  ▸ PostToolUse  (0)                                            │
│  ▸ Stop  (0)                                                   │
│  ▸ UserPromptSubmit  (0)                                       │
│  ▸ Notification  (0)                                           │
│                                                                │
│                                            [+ Add hook]        │
└────────────────────────────────────────────────────────────────┘
```

**Add hook sheet**: event picker + matcher (정규식 or literal) + command (필수) + timeout. 빈 command 거절.

### 9.11 Diagnostics 탭

- **Section: Schema versions** — installed_plugins.json (V1/V2/unknown), known_marketplaces.json, blocklist.json.
- **Section: Orphaned cache** — 리스트 + 총 크기. "Clean all" 버튼 (확인 다이얼로그).
- **Section: Plugin load errors** — pluginID + 메시지. 클릭 시 해당 플러그인 Installed detail 로 이동.
- **Section: Conflicting scopes** — 같은 ID 가 user/project/local 에 다른 enabled 값.
- **Section: Blocklist** — read-only 표시.
- **Section: Running Claude sessions** — pgrep 결과, 변경 보류 시 강조.

### 9.12 Preferences 윈도우 (⌘+,)

- **General**: 자동 시작 (SMAppService toggle), 메뉴바 숫자 배지 표시, 알림 권한.
- **CLI Path**: 해석된 `claude` 경로 표시 + "Reset" + "Choose..." (NSOpenPanel).
- **Backups**: 백업 디렉토리 경로 (`CC_PM_BACKUP_DIR`), 보관 일수.
- **Updates**: Sparkle update channel (stable / beta), check now.
- **Advanced**: 로그 레벨, "Reveal logs in Finder", schema drift mode (strict / lenient).

### 9.13 디자인 토큰 / 접근성

- **컬러**: `Color.accentColor` (시스템) + state dot 4색.
- **타이포그래피**: SF Pro (시스템 기본), monospace 는 SF Mono.
- **다크/라이트**: 자동 (SwiftUI 기본). 메뉴바 아이콘은 template image 라 자동 invert.
- **VoiceOver**: 모든 액션 버튼 `.accessibilityLabel` 명시. Table 행은 `.accessibilityValue` 로 status 보조 설명.
- **i18n**: `Localizable.strings` 키 — `installed.tab.title`, `marketplace.add.button` 등. 1차 ko/en.

---

## 10. 보안 & 안전성

### 10.1 위협 모델
- 악성 마켓이 공식 마켓 사칭 → `MarketplaceNameGuard.isBlocked` (PRD §7.5) + 비ASCII 체크.
- 악성 플러그인의 path traversal → install path 가 `~/.claude/plugins/cache` 안에 있는지 검증.
- 사용자 settings.json 손상 → 모든 쓰기 전 백업.
- 명령 인젝션 (CLI bridge) → Swift `Process` 의 `executableURL` + `arguments[]` 만 사용 (PRD §5.1).
- macOS 공증 우회 → Hardened Runtime + 공증 + stapling 강제. `com.apple.security.cs.disable-library-validation` 비허용.

### 10.2 안전 가드
- Mutation 액션은 항상 confirm dialog (Preferences 에서 "Skip confirmations for non-destructive" 토글 옵션).
- `managed` scope 자원은 read-only (mutation 시 SwiftUI Alert 으로 즉시 거절).
- seed marketplace (admin-managed) 는 read-only 배지 + 컨트롤 disabled.
- 매니저는 schema 미지의 V3 파일 만나면 read-only mode + 풀 윈도우 상단 노란색 배너.
- V1 schema 감지 시: "Migrate via `claude plugin migrate` 후 다시 시작" 안내 다이얼로그.

### 10.3 백업 정책
- 모든 mutation 직전, 대상 파일을 `~/Library/Application Support/com.toby.ccplugin/backups/<file>-<ts>.json` 으로 복사 (또는 `CC_PM_BACKUP_DIR` override).
- 동일 트랜잭션(< 1초 내 동일 파일) 은 백업 1회로 dedupe.
- 백업 보관 기간: 30일 (자동 정리, 앱 시작 시 swept).
- "Restore from backup" 메뉴: Preferences > Backups 탭 — 시간순 리스트.

### 10.4 파일 잠금 (File Locking) — v2.1 재작성

> M0 spike (PRD §부록 E v2.1) 결과: Claude Code 가 **파일별로 다른 동시성 정책**을 사용 → 매니저도 같은 비대칭을 따라야 호환됨.

#### 10.4.1 파일별 정책 매트릭스

| 파일 | Claude Code 의 정책 | 매니저 정책 (호환) | 근거 |
|---|---|---|---|
| `~/.claude/settings.json` (모든 scope) | proper-lockfile (디렉토리 락) + atomic rename | **proper-lockfile 호환 디렉토리 락** + atomic rename | `src/utils/config.ts` 가 `lockfile.lockSync(file, { lockfilePath: '${file}.lock' })` 사용 |
| `~/.claude/plugins/installed_plugins.json` | 락 미사용, **atomic rename only** | **atomic rename only** (락 추가 시 오히려 호환성 깨짐) | `src/utils/plugins/*` 의 grep 결과 lockfile 미사용 |
| `~/.claude/plugins/known_marketplaces.json` | 동상 — atomic rename only | atomic rename only | `zipCacheAdapters.ts:56` 주석 "atomic swap" |
| `~/.claude/plugins/blocklist.json` | atomic rename only | atomic rename only (read-only 권장) | – |
| `~/.claude/plugins/install-counts-cache.json` | atomic rename only | 매니저 미터치 (Claude Code 전용 캐시) | – |
| 사용자 자산 (`~/.claude/{skills,agents,commands}/*`) | – (개별 파일) | atomic rename per file | – |

#### 10.4.2 settings.json 락 — proper-lockfile 호환 구현

proper-lockfile 의 디스크 형식: `${file}.lock` 을 **디렉토리** 로 mkdir, 내부에 metadata 파일 (대부분 빈 디렉토리). 락 해제 시 rmdir.

Swift 측 호환 구현:

```swift
// PluginCore/Locking/ProperLockfileCompat.swift
public actor ProperLockfileCompat {
    public enum AcquireError: Error { case timeout, busy }

    public func acquire(forFile file: URL,
                        timeout: Duration = .seconds(10)) async throws {
        let lockDir = file.deletingLastPathComponent()
            .appending(path: file.lastPathComponent + ".lock")
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            do {
                // mkdir 자체가 atomic — 디렉토리가 이미 있으면 EEXIST
                try FileManager.default.createDirectory(
                    at: lockDir, withIntermediateDirectories: false)
                return  // 성공
            } catch CocoaError.fileWriteFileExists {
                // 다른 프로세스가 락 보유 중 — stale 검사
                if try await isStale(lockDir, threshold: .seconds(300)) {
                    try? FileManager.default.removeItem(at: lockDir)
                    continue
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw AcquireError.timeout
    }

    public func release(forFile file: URL) async {
        let lockDir = file.deletingLastPathComponent()
            .appending(path: file.lastPathComponent + ".lock")
        try? FileManager.default.removeItem(at: lockDir)
    }
}
```

- **Stale 감지**: lockfile 디렉토리 mtime > 5분 → 보유자 죽었거나 응답 없음 → cleanup 후 재시도.
- **Cross-process 호환**: Node `proper-lockfile` 도 같은 디렉토리를 사용 → 양쪽이 같은 락 인지.

#### 10.4.3 plugin 매니저 파일 — atomic rename only

```swift
// PluginCore/Writers/AtomicWriter.swift
public enum AtomicWriter {
    public static func write(_ data: Data, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        let tmp = dir.appending(path: ".\(dest.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])  // .atomic = NSData 내장 rename
        try FileManager.default.moveItem(at: tmp, to: dest)  // POSIX rename(2)
    }
}
```

> Foundation `Data.write(options: .atomic)` 자체가 이미 `tmp file → rename` 패턴이라 `moveItem` 단계가 사실상 중복. 단, dest 가 dir 내부의 다른 파일을 덮어쓰는 명확성을 위해 2단계 유지.

#### 10.4.4 Acquire 정책 (settings.json 한정)

- 첫 시도 즉시 실패 시 50ms backoff retry, 최대 10초.
- 10초 timeout → SwiftUI Alert: "Claude Code 가 settings.json 을 사용 중입니다 — Retry / Cancel".
- Stale lockfile (mtime > 5분) 감지 시 사용자 확인 후 cleanup.
- Lock 보유 상태에서만 atomic rename. 둘 다 만족해야 cross-process 안전.
- **MainActor 격리**: actor `ProperLockfileCompat` 내부에서 처리, UI 스레드 블로킹 금지.

#### 10.4.5 Lock interop test (PRD §11 추가 테스트)

- 매니저 Swift 락이 settings.json.lock 디렉토리를 점유한 동안 Node `proper-lockfile.lock(file)` 호출이 차단되는지 검증.
- 반대로 Node 가 점유한 동안 매니저 acquire 가 timeout 하는지 검증.
- 양방향 정상 동작 시에만 R12 (lockfile 호환) 통과.

### 10.5 Sandbox 정책

- **App Sandbox: OFF** (entitlement `com.apple.security.app-sandbox = false`).
- **Hardened Runtime: ON** — 공증 필수.
- **이유**: Mac App Store 비대상. `~/.claude` 임의 R/W + 외부 git/CLI 호출은 sandbox 정책상 통과 어려움. Developer ID 배포 + 공증으로 보안 보장.
- **장기 옵션**: 향후 MAS 진입 검토 시 `temporary-exception.files.home-relative-path.read-write = ['/.claude/']` + security-scoped bookmark 패턴 도입.

---

## 11. 검증 & 테스트 전략

### 11.1 Schema Drift 테스트 — Golden Fixture 라운드트립

```swift
// Tests/PluginCoreTests/SchemaRoundtripTests.swift
import XCTest
@testable import PluginCore

final class SchemaRoundtripTests: XCTestCase {
    func testInstalledPluginsV2Roundtrip() throws {
        let url = Bundle.module.url(
            forResource: "installed_plugins_real",
            withExtension: "json")!
        let original = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(InstalledPluginsFileV2.self, from: original)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let reEncoded = try encoder.encode(parsed)

        // semantic equivalence (key 순서/공백 무시)
        let originalNorm = try JSONSerialization.jsonObject(with: original)
        let reEncodedNorm = try JSONSerialization.jsonObject(with: reEncoded)
        XCTAssertTrue(equalIgnoringFormatting(originalNorm, reEncodedNorm))
    }
}
```

- Fixture 캡처: 본인 환경의 `~/.claude/plugins/{installed_plugins,known_marketplaces,blocklist}.json` 을 commit.
- vendor 핀 갱신: `./Scripts/sync-claude-fixtures.sh` 가 `vendor/claude-code` 서브모듈을 새 commit 으로 옮긴 뒤 fixture 재캡처.

### 11.2 CLI Bridge 검증

- `claude plugin list --json`, `claude plugin marketplace list --json` 등 모든 사용 명령의 실제 출력을 `Tests/Fixtures/cli/` 에 캡처.
- 출력 형태 변경 시 fixture 비교 실패 → 사람 개입.
- **Pre-M1 spike** (PRD §12 M0) 의 산출물이 곧 첫 fixture set.

### 11.3 단위 / 통합 테스트 (XCTest)

- **Readers**: 각 파일 fixture 로딩 + Codable 파싱 라운드트립. `~/.claude` snapshot 기반.
- **Writers**: 동시성 테스트 — `await withTaskGroup` 으로 N개 task 가 동일 파일을 mutation 시 데이터 손실 없음 + lockfile 정상 cleanup.
- **Lock interop test (R12 게이트)**: Swift 매니저가 `settings.json.lock` 디렉토리를 점유 중일 때 Node `proper-lockfile` 의 `lock()` 호출이 EEXIST/timeout 으로 차단되는지 검증. 반대로 Node 점유 시 Swift acquire 도 차단. **양방향 통과 시에만 settings.json mutation 머지 허용** (PRD §10.4.5).
- **Bridge ProcessRunner Security tests**: 사용자 입력에 `;`, `|`, `$(...)` 포함 시 그대로 argv 로 전달되어 쉘 해석되지 않음을 검증. Mock executable (echo) 로 stdout 확인.
- **Bridge Operations**: `claude` 바이너리 mock (Swift Process spawn 가능한 stub script) 으로 exit code 분기 검증.
- **CLI fixture roundtrip**: `spike/cli-fixtures/{plugin-list,marketplace-list}.json` 을 `Tests/Fixtures/cli/` 로 이관 후 Swift 도메인 모델로 디코드 → 인코드 라운드트립 검증.
- **PluginID / NameGuard**: 정규식 + 사칭 차단 케이스 30개 이상.
- **SwiftUI**: `ViewInspector` 또는 snapshot test (옵션) 로 Installed/Marketplaces 탭 렌더 검증.

### 11.4 E2E (수동 + CI 별도)

- 격리 환경: `CLAUDE_CONFIG_DIR=/tmp/cc-pm-e2e-<uuid>` 환경변수 주입 후 매니저 실행. PluginCore 의 `ClaudePaths` 가 이 변수를 우선.
- 시나리오: add marketplace → browse → install → enable → disable → uninstall → remove marketplace.
- 각 단계에서 디스크 snapshot 검증 (test helper 가 `~/.claude/plugins/installed_plugins.json` 등을 dump 하여 fixture 와 diff).

### 11.5 회귀 환경

- Claude Code CLI 바이너리 버전을 vendor submodule commit 으로 핀. CI 에서 동일 버전으로 E2E.
- 분기 정책: Claude Code 마이너 버전 업마다 schema drift 테스트 재실행 + manual smoke.
- CI: GitHub Actions macOS-latest runner. Xcode `xcodebuild test` + `swift test` 두 트랙.

### 11.6 배포 전 검증 (Pre-release Gate)

- `codesign --verify --strict --deep <app>` 통과.
- `spctl -a -v <app>` (Gatekeeper) 통과.
- `xcrun stapler validate <app>` (notarization staple) 통과.
- 첫 실행 후 메뉴바 아이콘 표시 < 1초.
- `instruments -l 30000 -t "Time Profiler" <app>` 으로 idle 30초간 평균 CPU < 0.1%.

---

## 12. 마일스톤 / 로드맵 (8주, 1인 풀타임 기준)

### M0 (Pre-M1, 1주) — Spike + 인프라
- [ ] `claude plugin list --json`, `marketplace list --json`, `marketplace add --dry-run` 출력 캡처 → §11.2 fixture 시드
- [ ] Apple Developer Program 가입 (또는 기존 계정 확인) + Developer ID Application 인증서 발급
- [ ] Sparkle EdDSA 키 생성, GitHub Releases 호스팅 셋업
- [ ] Xcode 워크스페이스 + Swift Package 스켈레톤 (`PluginCore` + `App` + `Tests`)
- [ ] `vendor/claude-code` 서브모듈 (PRD 작성 시점 commit 핀)
- [ ] `Scripts/notarize.sh`, `Scripts/build-dmg.sh`, `Scripts/sign.sh` 골격
- **Done when**: 빈 메뉴바 앱이 로컬 빌드 + 공증 dry-run 까지 통과

### M1 (W2, 2주) — Read-only Inventory + Menubar Shell
- [ ] PluginCore: 모든 zod 스키마를 Swift Codable 로 미러 (`Schemas/*.swift`)
- [ ] PluginCore: Readers (Settings, Installed, Marketplace, UserAsset)
- [ ] PluginCore: ClaudePaths (`CLAUDE_CONFIG_DIR` override)
- [ ] PluginCore: SchemaRoundtripTests (PRD §11.1)
- [ ] PluginCore: ClaudeCLIPathResolver (PRD §5.2 fallback chain)
- [ ] App: 메뉴바 아이콘 + popover (status line + Open Full Manager 버튼)
- [ ] App: NSWindow 풀 매니저 + Sidebar + Installed 탭 (read-only)
- [ ] App: Marketplaces 탭 (read-only)
- **Done when**: 본인 환경 (`~/.claude`) 에서 26개 플러그인 / 6개 마켓 정확히 popover/윈도우에 표시. ⌘Q 외 닫기 시 메뉴바 잔류

### M2 (W4, 1.5주) — Marketplace Mutation
- [ ] PluginCore: ProcessRunner + ClaudeCLI + Bridge.MarketplaceOperations
- [ ] PluginCore: BackupService + FileLock
- [ ] PluginCore: FSEventsWatcher → 변경 자동 감지
- [ ] App: Add Marketplace sheet (모든 6 source type 폼)
- [ ] App: Refresh / Refresh All / Remove / Toggle autoUpdate
- [ ] App: Confirm dialog SwiftUI 패턴 정착
- [ ] Sparkle: 첫 in-app 업데이트 라운드트립 검증
- **Done when**: 마켓 add → remove 라운드트립, refresh-all 진행률 표시, 자동 업데이트 정상

### M3 (W5.5, 2주) — Plugin Lifecycle
- [ ] PluginCore: Bridge.{Install,Uninstall,Enable,Disable,Update}Operation
- [ ] App: Browse 탭
- [ ] App: InstallDialog (scope + userConfig form auto-gen + dependencies closure preview)
- [ ] App: Bulk operations (멀티선택 enable/disable/update)
- [ ] App: Reload Hint 강화 (pgrep 기반 Claude 세션 감지)
- [ ] Notification: Update 사용 가능 알림
- **Done when**: 마켓에서 새 플러그인 install → enable → disable → uninstall 라운드트립 정상

### M4 (W7.5, 1.5주) — User Assets + Diagnostics + 배포
- [ ] PluginCore: UserAssetWriter + classifyPath (plugin-managed vs user-owned)
- [ ] PluginCore: SettingsWriter (hooks CRUD)
- [ ] PluginCore: DiagnosticsRunner
- [ ] App: User Assets 탭 (Skills/Agents/Commands)
- [ ] App: Hooks 탭 + Add hook sheet
- [ ] App: Diagnostics 탭
- [ ] App: Preferences 윈도우
- [ ] 공증 + dmg + Homebrew Cask 첫 배포
- **Done when**: SessionStart hook 추가 → Claude Code 재시작 후 정상 발화. dmg 다운로드 → 설치 → 자동 시작 → 자동 업데이트 라운드트립

### M5 (Phase 2, 선택) — 확장
- 멀티 머신 dotfiles 동기화 (export/import)
- Marketplace 검색 (HTTP → registry 연동)
- 통계 / 사용 빈도 시각화
- iPad 보조 view (CloudKit 동기화)

### 12.5 배포 파이프라인 (Distribution Pipeline)

```
[git tag v0.x.y]
       ↓
[GitHub Actions: macOS-latest]
       ↓
[xcodebuild archive → .xcarchive → ExportArchive → Developer ID signed .app]
       ↓
[xcrun notarytool submit --wait → 공증 결과]
       ↓
[xcrun stapler staple <app>]
       ↓
[Scripts/build-dmg.sh → ccplugin-v0.x.y.dmg]
       ↓
[Sparkle 도구로 EdDSA 서명 → ed-signature 추가]
       ↓
[GitHub Releases 업로드 + Scripts/update-appcast.sh → appcast.xml 갱신]
       ↓
[Homebrew Tap 저장소에 PR (sha256 + version 갱신)]
       ↓
[Sparkle 자동 업데이트 클라이언트가 다음 launch 시 검출]
```

**필수 자산**:
- `Apple Developer ID Application` 인증서 (Keychain).
- App-specific password (notarytool 용, App Store Connect).
- Sparkle EdDSA private key (CI secret, never commit).
- Homebrew Tap 저장소 (`tobylee/homebrew-ccplugin`).

---

## 13. 인수 기준 (Acceptance Criteria)

### F1 Installed
- [ ] 26개+ 플러그인 풀 윈도우 렌더 < 500ms
- [ ] 메뉴바 popover 첫 표시 < 200ms
- [ ] enable/disable 시 settings.json 반영 + 메뉴바 dot 노란색 + 풀 윈도우 status bar 배너
- [ ] uninstall 시 reverse-dependents 가 1개 이상이면 SwiftUI Alert 으로 차단 또는 강제 옵션
- [ ] update 진행률 실시간 stream (SwiftUI ProgressView), 실패 시 이전 버전 유지

### F2 Marketplace
- [ ] add 시 `MarketplaceNameGuard.isBlocked` 매칭 이름은 거절 + Alert
- [ ] remove 시 해당 마켓 소속 플러그인 모두 함께 uninstall (cascade) 또는 명시적 안내
- [ ] refresh-all 시 각 마켓별 결과 정확히 표시 (성공/실패/no-change), 알림 발송 (Preferences 옵션)

### F3 Browse → Install
- [ ] dependencies 가 있는 플러그인 install 시 closure 미리보기 (설치 예정 / 이미 설치 구분)
- [ ] userConfig 의 sensitive 키는 SecureField 마스킹 + "Show" 토글
- [ ] install 후 Installed 탭에 자동 추가 + Reload Hint 갱신

### F4 User Assets
- [ ] plugin-managed 디렉토리는 edit 시 disabled + tooltip 안내
- [ ] user-owned skill 신규 생성 후 SKILL.md 가 디스크에 존재 + FSEventsWatcher 에 의해 즉시 리스트 갱신

### F5 Hooks
- [ ] SessionStart 이벤트에 hook 추가 후 settings.json 정확히 반영 (`additionalKeys` passthrough 보존)
- [ ] hook entry 의 `command` 필드가 비어있으면 저장 거절 (sheet "Save" 버튼 disabled)

### Menubar / macOS-specific
- [ ] 로그인 후 메뉴바 아이콘 노출까지 < 1초
- [ ] 메인 윈도우 ⌘W 닫아도 메뉴바 잔류, ⌘Q 만 완전 종료
- [ ] Idle 시 메모리 < 50MB, CPU < 0.1%
- [ ] FSEventsWatcher 가 외부 변경 (다른 도구로 settings.json 수정) 감지 후 < 1초 내 UI 갱신
- [ ] dmg 다운로드 → 설치 → 자동 시작 → Sparkle 자동 업데이트 라운드트립 정상

### NFR
- [ ] 동일 시각에 Claude Code 세션과 매니저가 settings.json 을 동시 수정 시도 시 데이터 손실 없음 (flock 검증)
- [ ] schema V3 만나면 read-only mode 자동 진입 + 노란 배너 표시
- [ ] mutation 직전 백업 파일 항상 생성 (단, 동일 트랜잭션 dedupe)
- [ ] 모든 자식 프로세스 호출은 Swift `Process` + `executableURL` + `arguments[]` (쉘 미사용) — SwiftLint 로 강제
- [ ] 공증된 dmg 가 새 macOS 머신에서 Gatekeeper 통과 후 첫 실행 가능

---

## 14. 위험 & 완화 (Risk Register)

| ID | 위험 | 영향 | 가능성 | 완화 |
|---|---|---|---|---|
| R1 | Claude Code CLI 옵션/JSON 출력 변경 | 매니저 mutation 전체 마비 | 중 | CLI 호출을 protocol 추상화로 격리. vendor 핀. fixture 회귀 테스트 (PRD §11.2) |
| R2 | installed_plugins.json V2 → V3 schema 변경 | 데이터 깨짐 | 저 | read-only 자동 전환 + 사용자 안내 (Codable init throw) |
| R3 | 동시성 (Claude Code 세션과 동시 쓰기) | 설정 손상 | 중 | flock + atomic rename + mtime 비교 + 백업 |
| R4 | git clone/pull 인증 실패 | 마켓 add/refresh 불가 | 중 | CLI bridge 가 처리 → 매니저는 결과 메시지만 노출 |
| R5 | userConfig sensitive 누출 | 보안 사고 | 저 | SecureField + 로그 redact + Keychain 위임 (Claude Code 메커니즘) |
| R6 | 본인 매니저 버그로 settings.json 망침 | 사용자 환경 손상 | 중 | 백업 + 모든 쓰기 락 + 단위 테스트 + Restore 메뉴 |
| R7 | seed marketplace 잘못 건드림 | 사용자 옵션 박탈 | 저 | seed 감지 후 SwiftUI 컨트롤 disabled |
| R8 | 명령 인젝션 (사용자 입력 → 쉘) | 임의 코드 실행 | 저 | `executableURL` + `arguments[]` 강제, SwiftLint 차단 |
| **R9** | **GUI 앱 PATH 미상속으로 `claude` CLI 못 찾음** | **앱 첫 실행 시 mutation 전체 불가** | **고** | **§5.2 fallback chain (env → 알려진 경로 → 로그인 셸 → 사용자 선택)** |
| **R10** | **App Sandbox 정책으로 `~/.claude` 접근 차단** | **read 자체 불가** | **저** | **Sandbox OFF + Developer ID 배포 채택 (§10.5)** |
| **R11** | **Apple 공증 거절 / 인증서 만료** | **신규 사용자 설치 불가** | **중** | **CI 파이프라인에 공증 dry-run gate (§11.6) + 인증서 만료 알림 캘린더 등록** |
| **R12** | **Claude Code 의 lockfile 규약과 우리 flock 이 호환 안 됨** | **동시성 가드 무력화** | **중** | **vendor 의 `proper-lockfile` 동작 검증 후 동일 lockfile 이름/경로 채택. M1 spike 에 포함** |
| **R13** | **Sparkle EdDSA 키 유출** | **악성 업데이트 강제 배포 가능** | **저** | **CI secret 격리 + 다중 인원 접근 제한 + 키 회전 절차 문서화** |
| **R14** | **macOS 14/15 신버전에서 MenuBarExtra/SMAppService 동작 변경** | **로그인 자동 시작 / popover 깨짐** | **저** | **macOS 13 minimum 유지 + 베타 OS 정기 검증 (releases.apple.com 모니터링)** |

---

## 15. 미해결 질문 (Open Questions)

> v2.2 갱신: Q2, Q8 RESOLVED (Q2/Q8 spike 결과 — `spike/REPORT.md` 부록). Q9 신규 추가.

1. **CLI bridge 인증/proxy**: 사내 git mirror 사용자는 환경변수 의존. 매니저가 GUI 환경에서 사용자 shell 환경변수를 어떻게 흡수? 로그인 셸 1회 dump (`zsh -l -c env`) 후 캐시?
2. ~~**Marketplace remove cascade**~~ ✅ **RESOLVED (v2.2)**: CLI 가 메타데이터 cascade 자동 (installed_plugins.json + enabledPlugins + extraKnownMarketplaces + known_marketplaces.json), cache 디렉토리만 orphan 으로 남김. 매니저는 OrphanedCacheDetector 로 처리. §F2.3 단순화됨.
3. **다중 머신**: 사용자가 여러 머신에서 동일 환경 원할 때, dotfiles 동기화 책임을 누가? 본 매니저는 export/import 만 (M5)?
4. **Plugin 자체 작성**: `plugin-dev` 플러그인 + `plugin validate` 가 이미 있는데, 매니저가 신규 플러그인 스캐폴딩까지 흡수?
5. **사용 통계**: 어떤 플러그인이 자주 호출되는지 telemetry → "안 쓰는 플러그인 정리 추천"? Privacy-first 라면 로컬 only.
6. **macOS minimum 진화**: macOS 14 (`@Observable`, 더 강력한 SwiftData) 로 올리면 코드 단순화 vs 사용자 베이스 축소. 결정 시점?
7. **Update stale 감지**: §S4 ("어제 마켓들이 새 버전을 냈다") 를 매니저가 어떻게 감지? `marketplace.json` lastUpdated vs installed version 비교 — 정확한 비교 키는 gitCommitSha (단, directory source 는 gitCommitSha 가 nil — 별도 처리 필요)?
8. ~~**userConfig 입력 채널**~~ ✅ **RESOLVED (v2.2)**: `install` CLI 는 userConfig 안 받음. enable 시점에 manifest schema 기반 prompt → sensitive 는 macOS Keychain (`security find-generic-password`), non-sensitive 는 settings.json `pluginConfigs[pluginId].options`. 매니저는 `pluginOptionsStorage` 메커니즘에 위임.
9. **CLI 스트리밍 vs 배치** (M0 부분 검증): `marketplace update` 가 stdout 에 진행률 라인을 흘리는지 vs 끝에 한 번에 출력하는지. UI 진행률 표시 방식 결정. M2 시작 시 실측.
10. **Directory source 마켓의 gitCommitSha 부재 처리**: Q2 spike 부수 발견 — directory source 로 install 된 플러그인은 `gitCommitSha` 가 없음. 매니저 view 에서 "version: 0.0.1 (local)" 같이 별도 배지? 또는 update 가능 여부 판단 시 mtime fallback?
11. **Marketplace.json schema micro-drift**: Q2 spike 부수 발견 — `claude plugin validate` 가 `$schema`, root `description` 키를 거절하지만 공식 마켓은 사용. `validate` 가 strict, 런타임은 lenient. 매니저의 사전 검증을 strict 으로 갈지 lenient 으로 갈지?

---

## 16. 용어집 (Glossary)

| 용어 | 정의 |
|---|---|
| **Plugin** | Claude Code 의 확장 단위. commands/agents/skills/hooks/mcp/lsp 묶음 |
| **Plugin ID** | `name@marketplace` 형식의 식별자 |
| **Marketplace** | 여러 플러그인을 묶어 배포하는 Git 저장소 또는 URL |
| **Scope** | 플러그인 활성화 범위. managed > user > project > local > flag |
| **Source** | 플러그인이나 마켓의 출처. github / git / git-subdir / url / npm / pip / file / directory |
| **Materialization** | settings.json 의 의도(intent)를 실제 디스크 상태로 동기화하는 단계 (Layer 2) |
| **Reconciler** | Claude Code 의 startup 단계에서 Layer 1 ↔ Layer 2 를 일치시키는 모듈 |
| **Reverse-dependents** | 어떤 플러그인을 dependency 로 선언한 다른 플러그인들 |
| **Cross-marketplace dependency** | 한 마켓의 플러그인이 다른 마켓의 플러그인을 의존. `allowCrossMarketplaceDependenciesOn` 화이트리스트 필요 |
| **userConfig sensitive** | 키체인 또는 `.credentials.json` 에 저장되는 비밀 옵션 |
| **MenuBarExtra** | macOS 13+ SwiftUI scene 으로 메뉴바 아이템 선언적 정의 |
| **NSStatusItem** | AppKit 의 메뉴바 아이템 — MenuBarExtra 가 내부적으로 사용 |
| **LSUIElement** | Info.plist 키 — `YES` 시 Dock 미노출, Cmd+Tab 미노출 ("UI element only") |
| **Hardened Runtime** | macOS 코드 사이닝 옵션 — JIT/dyld override 차단, 공증 필수 |
| **Notarization** | Apple 의 자동 악성코드 스캔 + 공식 서명. 배포 외 macOS 에서 실행 가능하게 함 |
| **Stapling** | 공증 ticket 을 .app/.dmg 안에 첨부 — 오프라인 검증 가능 |
| **Sparkle** | macOS 자동 업데이트 표준 라이브러리. EdDSA 서명 + appcast.xml |
| **SMAppService** | macOS 13+ 공식 자동 시작 API (`mainApp.register()`) |
| **FSEventStream** | macOS 의 파일시스템 변경 감지 API (Carbon framework) |
| **App Sandbox** | macOS 앱 권한 격리. MAS 필수, Developer ID 배포는 옵션 |
| **Developer ID** | Apple 발급 인증서 — MAS 외 배포 시 코드 사인 + 공증에 사용 |

---

## 17. Claude Code 소스 참조 (Cross-Reference)

> 본 PRD 의 모든 동작은 다음 파일/라인에서 검증되었다. 매니저 개발 중 의문 발생 시 우선 이 파일들을 본다.

### 17.1 Schemas (단일 진실 소스)
- `src/utils/plugins/schemas.ts:884` `PluginManifestSchema`
- `src/utils/plugins/schemas.ts:1062` `PluginSourceSchema`
- `src/utils/plugins/schemas.ts:906` `MarketplaceSourceSchema`
- `src/utils/plugins/schemas.ts:1293` `PluginMarketplaceSchema`
- `src/utils/plugins/schemas.ts:1339` `PluginIdSchema`
- `src/utils/plugins/schemas.ts:1482` `InstalledPluginsFileSchemaV1`
- `src/utils/plugins/schemas.ts:1562` `InstalledPluginsFileSchemaV2`
- `src/utils/plugins/schemas.ts:1624` `KnownMarketplacesFileSchema`
- `src/utils/plugins/schemas.ts:19` `ALLOWED_OFFICIAL_MARKETPLACE_NAMES`
- `src/utils/plugins/schemas.ts:71` `BLOCKED_OFFICIAL_NAME_PATTERN`

### 17.2 핵심 Operations
- `src/services/plugins/pluginOperations.ts:321` `installPluginOp`
- `src/services/plugins/pluginOperations.ts:427` `uninstallPluginOp`
- `src/services/plugins/pluginOperations.ts:573` `setPluginEnabledOp`
- `src/services/plugins/pluginOperations.ts:756` `enablePluginOp`
- `src/services/plugins/pluginOperations.ts:770` `disablePluginOp`
- `src/services/plugins/pluginOperations.ts:782` `disableAllPluginsOp`
- `src/services/plugins/pluginOperations.ts:829` `updatePluginOp`
- `src/services/plugins/pluginOperations.ts:896` `performPluginUpdate`

### 17.3 CLI Wrappers
- `src/services/plugins/pluginCliCommands.ts:103` `installPlugin`
- `src/services/plugins/pluginCliCommands.ts:153` `uninstallPlugin`
- `src/services/plugins/pluginCliCommands.ts:195` `enablePlugin`
- `src/services/plugins/pluginCliCommands.ts:236` `disablePlugin`
- `src/services/plugins/pluginCliCommands.ts:300` `updatePluginCli`

### 17.4 Marketplace
- `src/utils/plugins/marketplaceManager.ts:1782` `addMarketplaceSource`
- `src/utils/plugins/marketplaceManager.ts:1937` `removeMarketplaceSource`
- `src/utils/plugins/marketplaceManager.ts:2296` `refreshAllMarketplaces`
- `src/utils/plugins/marketplaceManager.ts:2365` `refreshMarketplace`
- `src/utils/plugins/marketplaceManager.ts:2587` `setMarketplaceAutoUpdate`
- `src/utils/plugins/marketplaceManager.ts:2188` `getPluginByIdCacheOnly`

### 17.5 Refresh / Reconcile
- `src/utils/plugins/refresh.ts:72` `refreshActivePlugins`
- `src/utils/plugins/reconciler.ts` (Layer 2 동기화)

### 17.6 Installed Plugins File
- `src/utils/plugins/installedPluginsManager.ts:78` `getInstalledPluginsFilePath`
- `src/utils/plugins/installedPluginsManager.ts:115` `migrateToSinglePluginFile`

### 17.7 CLI Handlers
- `src/cli/handlers/plugins.ts:101` `pluginValidateHandler`
- `src/cli/handlers/plugins.ts:157` `pluginListHandler`

### 17.8 자식 프로세스 안전 호출 — Claude Code 내부 패턴 (참고)
- `src/utils/execFileNoThrow.ts` (Claude Code 가 모든 외부 명령 호출에 사용하는 안전 래퍼)
- `src/utils/plugins/marketplaceManager.ts:528` `gitPull` — execFile 기반 호출 예시
- `src/utils/plugins/marketplaceManager.ts:803` `gitClone` — execFile 기반 호출 예시

### 17.9 UI 참고 (벤치마킹 용)
- `src/commands/plugin/ManagePlugins.tsx` (2214 LOC)
- `src/commands/plugin/ManageMarketplaces.tsx` (837 LOC)
- `src/commands/plugin/BrowseMarketplace.tsx` (801 LOC)
- `src/commands/plugin/UnifiedInstalledCell.tsx` (564 LOC) — 셀 렌더링 모범

---

## 18. 부록 A — 환경 변수

Claude Code 가 사용하는 환경변수 (매니저는 이를 그대로 존중하며 override 하지 않는다):

| 변수 | 설명 | 기본 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` 의 override | `~/.claude` |
| `CLAUDE_CODE_PLUGIN_GIT_TIMEOUT_MS` | git pull/clone 타임아웃 | 120000 |
| `DISABLE_OMC` | OMC 스킬 비활성 (사용자 환경 특유) | – |
| `OMC_SKIP_HOOKS` | 특정 후크 스킵 | – |

매니저 자체 환경변수:

| 변수 | 설명 | 기본 |
|---|---|---|
| `CC_PM_BACKUP_DIR` | 백업 저장 위치 | `~/Library/Application Support/com.toby.ccplugin/backups` |
| `CC_PM_BACKUP_TTL_DAYS` | 백업 보관 일수 | 30 |
| `CC_PM_CLAUDE_BIN` | `claude` CLI 바이너리 경로 (해석 fallback chain 1순위) | – (해석 시 §5.2 적용) |
| `CC_PM_LOG_LEVEL` | 로그 레벨 (`debug` / `info` / `warning` / `error`) | `info` |
| `CC_PM_LOG_DIR` | 로그 디렉토리 override | `~/Library/Logs/com.toby.ccplugin` |
| `CC_PM_DISABLE_NOTIFICATIONS` | UNUserNotificationCenter 비활성 | – |
| `CC_PM_LOCK_TIMEOUT_SEC` | flock acquire timeout (PRD §10.4) | 10 |
| `CC_PM_DEV_DISABLE_NOTARIZATION_CHECK` | 개발 빌드용 — 절대 배포에 사용 금지 | – |

> **참고**: GUI 앱은 사용자 shell 의 환경변수를 상속하지 않는다. `CC_PM_*` 변수는 (a) `launchctl setenv`, (b) Preferences 윈도우 (영구), (c) 디버깅용 Xcode scheme env 중 하나로 설정한다.

---

## 19. 부록 B — 부트스트랩 명령 (Xcode + Swift Package)

### B.1 새 프로젝트 골격 만들기

```bash
# 1. 작업 디렉토리 (이미 ~/workspace/ai/ccplugin 사용 중이라면 skip)
cd ~/workspace/ai/ccplugin
git init -b main

# 2. Claude Code vendor 핀 (스키마 reference)
git submodule add https://github.com/anthropics/claude-code.git vendor/claude-code
( cd vendor/claude-code && git checkout 13615cf )   # PRD 분석 시점 commit

# 3. Xcode 프로젝트 생성 (GUI):
#    File → New → Project → macOS → App
#      Product Name:     ccplugin
#      Team:             <Apple Developer Team ID>
#      Organization ID:  com.toby
#      Bundle ID:        com.toby.ccplugin
#      Interface:        SwiftUI
#      Language:         Swift
#      Storage:          None
#    저장 위치: 현재 디렉토리 (./App/)

# 4. Swift Package 생성 (PluginCore)
mkdir -p Packages/PluginCore
cd Packages/PluginCore
swift package init --type library --name PluginCore
cd ../..

# 5. Xcode workspace 만들기
#    Xcode: File → New → Workspace → ccplugin.xcworkspace
#    워크스페이스에 ./App/ccplugin.xcodeproj + ./Packages/PluginCore 추가

# 6. App target 의 Package Dependencies 에 PluginCore 추가
#    + Sparkle (https://github.com/sparkle-project/Sparkle, exact: 2.6.0+)

# 7. Scripts 디렉토리
mkdir -p Scripts docs
```

### B.2 Info.plist 핵심 키 설정 (App target)

부록 D 참조.

### B.3 entitlements (App target → ccplugin.entitlements)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>            <false/>
  <key>com.apple.security.cs.allow-jit</key>            <false/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key> <false/>
  <key>com.apple.security.cs.disable-library-validation</key>       <false/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key> <false/>
</dict>
</plist>
```

### B.4 Build settings (App target)

| Key | Value |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `13.0` |
| `ENABLE_HARDENED_RUNTIME` | `YES` |
| `CODE_SIGN_STYLE` | `Manual` (CI) / `Automatic` (로컬) |
| `DEVELOPMENT_TEAM` | `<Team ID>` |
| `CODE_SIGN_IDENTITY` | `Developer ID Application` |
| `OTHER_CODE_SIGN_FLAGS` | `--timestamp --options runtime` |

### B.5 첫 빌드 / 실행 순서

1. `Packages/PluginCore/Sources/PluginCore/Schemas/InstalledPluginsV2.swift` 작성 (PRD §7.1).
2. `Packages/PluginCore/Sources/PluginCore/Paths/ClaudePaths.swift` 작성 — `CLAUDE_CONFIG_DIR` 우선 처리.
3. `Packages/PluginCore/Sources/PluginCore/Readers/InstalledReader.swift` 작성.
4. `Packages/PluginCore/Tests/PluginCoreTests/SchemaRoundtripTests.swift` 작성 — 본인 `~/.claude/plugins/installed_plugins.json` 을 fixture 로 commit (sensitive 가 없는지 확인 후).
5. `swift test` 통과 확인.
6. `App/ccpluginApp.swift` 에 `MenuBarExtra` scene 작성 — placeholder popover.
7. Xcode Run → 메뉴바에 아이콘 표시되는지 확인.

### B.6 매니저 자체 첫 실행 self-test (M0 산출물)

```swift
// App/Services/SelfTest.swift
@MainActor
public func runSelfTestOnFirstLaunch() async {
    var issues: [String] = []
    do { _ = try await ClaudePaths.resolveConfigDir() }
    catch { issues.append("CLAUDE_CONFIG_DIR resolution failed: \(error)") }
    do { _ = try await ClaudeCLIPathResolver.shared.resolve() }
    catch { issues.append("`claude` CLI not found — set in Preferences") }
    do { try await BackupService.shared.ensureBackupDirectory() }
    catch { issues.append("Backup directory not writable: \(error)") }
    if !issues.isEmpty {
        showFirstLaunchAlert(issues: issues)
    }
}
```

---

## 20. 부록 C — 결정 로그 시드 (Decision Log)

| 일자 | 결정 | 근거 |
|---|---|---|
| 2026-04-26 (v1.0) | CLI Bridge 1차 채택 | dependency closure resolution + git auth 재구현 비용 회피 |
| 2026-04-26 (v1.0) | TUI ink 선택 | Claude Code 와 동일 stack, drift 시 학습 비용 ↓ |
| 2026-04-26 (v1.0) | zod 스키마 미러 | drift 자동 감지 가능, runtime 검증 일관 |
| 2026-04-26 (v1.0) | proper-lockfile 채택 | Claude Code 와 동일 락 메커니즘으로 호환 |
| 2026-04-26 (v1.0) | 자식 프로세스는 execFile/spawn 만 사용 | 명령 인젝션 방지, Claude Code 자체 규약과 일치 |
| **2026-04-26 (v2.0)** | **TUI(ink) 폐기 → macOS 메뉴바 native 앱 전환** | **사용자 요구: 메뉴바 상주, 한 클릭으로 열기. 학습/노력 절감보다 UX 중요** |
| **2026-04-26 (v2.0)** | **언어 Node/TS → Swift 5.9** | **메뉴바 앱 합격선 (시작 < 200ms, 메모리 < 50MB) 충족. Foundation `Process` 보안 모델 동일** |
| **2026-04-26 (v2.0)** | **zod 미러 → Swift Codable 미러** | **언어 변경에 따른 자연 귀결. drift test 는 golden fixture 라운드트립으로 1단계 시작** |
| **2026-04-26 (v2.0)** | **`proper-lockfile` → POSIX `flock(2)` + atomic rename** | **Swift 환경 적합. lockfile 이름 규약은 Claude Code 와 호환되도록 검증 (R12)** |
| **2026-04-26 (v2.0)** | **Sandbox OFF + Developer ID 배포** | **`~/.claude` 임의 R/W 와 외부 git 호출 패턴이 MAS 심사 통과 어려움. Homebrew Cask 친화** |
| **2026-04-26 (v2.0)** | **Sparkle 2.x 자동 업데이트** | **메뉴바 앱은 사용자가 거의 안 닫음 → in-app 업데이트 필수. EdDSA 서명 표준** |
| **2026-04-26 (v2.0)** | **macOS 13.0 minimum** | **MenuBarExtra + SMAppService 사용 가능. 신구 OS 균형** |
| **2026-04-26 (v2.0)** | **MVP 4주 → 8주 재조정** | **Mac native 인프라 비용 (공증, Sparkle, dmg, 코드 사이닝) +4주 추가** |
| **2026-04-26 (v2.0)** | **enable/disable 등 단순 mutation 은 direct fallback 우선** | **CLI 0.5–2초 vs 직접 < 10ms — 메뉴바 앱 UX 합격선과 직결** |

---

## 21. 부록 D — Info.plist 템플릿

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 메뉴바 전용 앱: Dock 미노출, Cmd+Tab 미노출 -->
    <key>LSUIElement</key>
    <true/>

    <!-- 최소 macOS 버전 -->
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>

    <key>CFBundleIdentifier</key>
    <string>com.toby.ccplugin</string>

    <key>CFBundleName</key>
    <string>Claude Plugin Manager</string>

    <key>CFBundleDisplayName</key>
    <string>Claude Plugin Manager</string>

    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>

    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>

    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <!-- Sparkle 자동 업데이트 -->
    <key>SUFeedURL</key>
    <string>https://github.com/tobyilee/ccplugin/releases/download/appcast/appcast.xml</string>

    <key>SUPublicEDKey</key>
    <string><!-- EdDSA public key, base64 --></string>

    <key>SUEnableInstallerLauncherService</key>
    <true/>

    <!-- Sparkle 채널 (stable / beta) - 옵션 -->
    <key>SUAllowedChannels</key>
    <array>
        <string>stable</string>
    </array>

    <!-- 자동 시작 (Login Items) — SMAppService 가 처리 -->
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>

    <!-- 알림 권한 사용 의도 명시 -->
    <key>NSUserNotificationsUsageDescription</key>
    <string>Marketplace 갱신 결과와 사용 가능한 업데이트를 알려드립니다.</string>

    <!-- 다른 앱(터미널/Claude Code) 자동화는 사용 안 함이지만,
         pgrep 호출이 정책 검사에 걸리지 않게 하려면 비워두기 -->

    <!-- 다국어 -->
    <key>CFBundleLocalizations</key>
    <array>
        <string>ko</string>
        <string>en</string>
    </array>

    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
</dict>
</plist>
```

**주의 사항**:
- `LSUIElement = YES` 가 핵심 — 이것 없이는 Dock 아이콘이 뜨고 메뉴바 앱이 아닌 일반 앱이 됨.
- `SUFeedURL`, `SUPublicEDKey` 는 Sparkle 통합 시 필수. EdDSA 키 분실 시 자동 업데이트 채널이 영구히 깨지므로 **백업 필수** (CI secret + 오프라인 사본 2부).
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 은 Xcode build settings 에서 주입 — `agvtool` 또는 CI 에서 git tag 기반 자동화.

---

## 22. 부록 E — 변경 이력 (Changelog)

### v2.2 (2026-04-26) — Q2/Q8 destructive verification

- **DATA**: 일회성 directory-source 마켓 (`/tmp/cc-pm-spike/test-market`) 으로 add → install → remove 라운드트립 검증 → 사전 상태 정확히 복원.
- **RESOLVE §15.Q2** (cascade): CLI `marketplace remove` 는 메타데이터 cascade 자동 (installed_plugins / enabledPlugins / extraKnownMarketplaces / known_marketplaces). cache 디렉토리만 orphan → OrphanedCacheDetector 책임.
- **RESOLVE §15.Q8** (userConfig): install CLI 는 userConfig 미수집. enable 시점에 manifest schema 기반 prompt. sensitive → macOS Keychain (security CLI 위임), non-sensitive → settings.json `pluginConfigs[pluginId].options`. Manager 는 `pluginOptionsStorage` 위임만.
- **SIMPLIFY §F2.3**: v2.1 의 "명시적 3단계 트랜잭션" 폐기 → 단일 CLI 호출 + cache cleanup 안내로 단순화.
- **NEW §15.Q10**: directory source 의 gitCommitSha 부재 처리 (M2 결정 필요).
- **NEW §15.Q11**: marketplace.json schema micro-drift (`$schema`/root `description`) — strict vs lenient 검증 정책 결정 필요.
- **NOTE Q9** (CLI streaming) 는 M2 진입 시 실측으로 미룸.

### v2.1 (2026-04-26) — M0 spike calibration
- **DATA**: `claude` 2.1.119 의 실제 명령 표면 + `--json` 출력 스키마 캡처. `spike/cli-fixtures/` 11개 파일.
- **CORRECT §1.7**: 존재하지 않던 명령 정정 — `marketplace refresh` ✗ → `marketplace update` ✓, `auto-update <name> on|off` ✗ → settings.json direct mutation only, `disable-all` 별도 서브커맨드 ✗ → `disable -a, --all` 플래그.
- **CORRECT §6.1**: Read 경로를 "CLI list + Direct file read 합성" 으로 명시 — CLI 출력은 disk schema 의 부분집합. Mutation 경로를 1차 (CLI) / 1.5차 (settings.json patch) / 2차 (atomic rename) / 예외 (boolean flip UX) 4단계로 세분화.
- **CORRECT §10.4**: 파일별 비대칭 lockfile 정책 — settings.json 만 proper-lockfile (디렉토리 락) 호환, plugin manager 파일 (installed_plugins.json/known_marketplaces.json/blocklist.json) 은 atomic rename only. Swift `ProperLockfileCompat` 코드 골격 추가.
- **NEW §11.3**: Lock interop test — Swift ↔ Node `proper-lockfile` 양방향 차단 검증 (R12 게이트).
- **NEW §11.3**: CLI fixture roundtrip test — `spike/cli-fixtures/*.json` → Swift 도메인 모델 디코드/인코드 라운드트립.
- **UPDATE §F1.1**: Source 합성 명세 — CLI + installed_plugins.json + cache 의 plugin.json + 디렉토리 스캔 4단계. `PluginManifestReader` 우선순위 ↑ (M1 critical path).
- **UPDATE §F2.2**: Add 흐름을 2단계 트랜잭션으로 — CLI add → settings.json patch (ref/path/autoUpdate 백필).
- **UPDATE §F2.3**: Cascade 미검증 → 명시적 3단계 트랜잭션 (list → uninstall N번 → marketplace remove) 임시 채택.
- **UPDATE §F2.4**: `marketplace refresh` → `marketplace update` 정정.
- **UPDATE §F2.5**: autoUpdate 토글은 Direct settings.json mutation only 명시.
- **UPDATE §15**: Q2 (cascade) 검증 방법 명시. Q8 (userConfig 입력 채널), Q9 (CLI 진행률 스트리밍) 신규 추가.
- **REFERENCE**: M0 spike 산출물 `spike/REPORT.md` 를 헤더에서 cross-link.

### v2.0 (2026-04-26)
- **BREAKING**: TUI(ink + React) 결정 폐기 → macOS 메뉴바 native 앱 (Swift 5.9 + SwiftUI/AppKit) 채택.
- **BREAKING**: 언어 Node/TS → Swift. zod 미러 → Codable 미러.
- **BREAKING**: 패키지 레이아웃 monorepo (npm workspaces) → Xcode workspace + Swift Package.
- **NEW**: §6.0 Platform Decision (macOS 13+).
- **NEW**: §6.6 Menubar UX 패턴 (popover + 메인 윈도우 분리).
- **NEW**: §5.2 PATH 해석 (GUI 앱 PATH 상속 부재 처리).
- **NEW**: §10.4 File Locking (POSIX flock + atomic rename).
- **NEW**: §10.5 Sandbox 정책 (OFF + Developer ID).
- **NEW**: §11.6 Pre-release Gate (codesign / spctl / stapler).
- **NEW**: §12 M0 (Pre-M1 spike) + §12.5 배포 파이프라인 + 마일스톤 4주 → 8주.
- **NEW**: §부록 D Info.plist 템플릿.
- **UPDATE**: §13 인수 기준에 macOS-specific 항목 추가 (시작 시간, 메모리, FSEvents 반응 등).
- **UPDATE**: §14 Risk register 에 R9–R14 (PATH, Sandbox, 공증, lockfile 호환, Sparkle 키, OS 변경) 추가.

### v1.0 (2026-04-26)
- 최초 작성. CLI Bridge + TUI(ink) 기반 monorepo 설계.

---

**END OF PRD**
