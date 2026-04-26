# M0 Spike Report — CLI Bridge & Lockfile 검증

> **수행일**: 2026-04-26
> **수행자**: Toby Lee
> **목적**: PRD §11.2 fixture 시드 + R12 (lockfile 호환) 검증
> **소요 시간**: ~30분
> **분석 환경**: Claude Code CLI 2.1.119, macOS 25.3.0
> **분석 코드 reference**: `/Users/tobylee/workspace/ai/claudecode/src` (commit 13615cf)

---

## 1. TL;DR

| 항목 | 결과 | PRD 영향 |
|---|---|---|
| **CLI Bridge 1차 전략** | ✅ 유효, 단 **Direct file read 필수** | §6.1 결정 보강 — direct read 가 1.5차로 승격 |
| **R12 lockfile 호환** | ✅ 부분 호환 — settings.json 만 락 사용, plugin 파일은 atomic rename | §10.4 재작성 (settings.json 만 flock, 나머지는 atomic rename only) |
| **Marketplace autoUpdate CLI** | ❌ 노출 안 됨 → direct settings.json 편집 강제 | §F2.5 / §6.1 재확인 |
| **Marketplace `refresh`** | ❌ 명령 없음 — `update` 가 그 역할 | §1.7 표 갱신 |
| **`marketplace add` 에 `--ref`/`--auto-update`** | ❌ 옵션 없음 (`--scope`, `--sparse` 만) | §F2.2 폼 재설계 — 일부 필드는 add 후 settings.json edit 필요 |

**가장 큰 발견**: CLI 출력은 **disk JSON 파일의 부분집합**. 다음 핵심 필드가 CLI 에 노출되지 않음:
- `gitCommitSha` (installed_plugins.json 에 있음)
- `loadErrors` (CLI 에 errors[] 미노출)
- marketplace `lastUpdated`, `autoUpdate` (known_marketplaces.json 에 있음)
- marketplace 별 plugin count

→ **매니저는 CLI + 디스크 파일을 합쳐서 view model 을 구성해야 한다**.

---

## 2. CLI 표면 — 실측

### 2.1 명령 목록 (claude plugin --help)

| 명령 | 옵션 | 비고 |
|---|---|---|
| `disable [plugin]` | `--scope`, `-a, --all` | scope 미지정 시 auto-detect |
| `enable <plugin>` | `--scope` | – |
| `install <plugin>` | `-s, --scope` (default user) | userConfig 입력 방법은 spike 미검증 (env/stdin?) |
| `list` | `--available`, `--json` | `--available` 은 `--json` 강제 |
| `marketplace add <source>` | `--scope`, `--sparse <paths...>` | `--ref`, `--auto-update` 없음 |
| `marketplace list` | `--json` | – |
| `marketplace remove <name>` | – | cascade 정책 spike 미검증 (실제 add/remove 테스트 필요) |
| `marketplace update [name]` | – | **이게 refresh 역할.** 이름 미지정 시 전체 |
| `tag [path]` | – | release용. 매니저 비대상 |
| `uninstall <plugin>` | `--scope`, `--keep-data` | – |
| `update <plugin>` | `--scope` (managed 포함) | "restart required to apply" — Layer 3 안내와 일치 |
| `validate <path>` | – | 매니저 read-only로 활용 가능 |

### 2.2 `claude plugin list --json` 스키마

```typescript
type PluginListJsonItem = {
  id: string;                     // "name@market"
  version: string;                // "unknown" 도 가능
  scope: "user" | "project" | "local" | "managed";
  enabled: boolean;
  installPath: string;            // 절대 경로
  installedAt: string;            // ISO 8601
  lastUpdated: string;            // ISO 8601
  mcpServers?: Record<string, {   // 옵션
    command: string;
    args?: string[];
  }>;
};
```

**디스크 vs CLI 비교**:

| 필드 | disk `installed_plugins.json` V2 | CLI `--json` |
|---|---|---|
| version | ✓ | ✓ |
| scope | ✓ | ✓ |
| installPath | ✓ | ✓ |
| installedAt | ✓ | ✓ |
| lastUpdated | ✓ | ✓ |
| **gitCommitSha** | **✓** | **✗** ❌ |
| **enabled** | ✗ (settings.json 에 있음) | **✓** ← cross-join 결과 |
| **mcpServers** | ✗ (manifest 에 있음) | **✓** ← manifest 미리 합쳐줌 |
| **loadErrors** | ✗ | ✗ ← 어디에도 없음 |
| **multi-scope array** | ✓ (배열) | ✗ (flat) |

> **결론**: CLI 의 `id` + `enabled` + `mcpServers` 합치기는 편하지만, `gitCommitSha`, V2 multi-scope, manifest 의 description/author/keywords 가 부족 → 디스크 파일 + cache 의 plugin.json 직접 읽기 필요.

### 2.3 `claude plugin marketplace list --json` 스키마

```typescript
type MarketplaceListJsonItem = {
  name: string;
  source: "git" | "github" | "url" | "npm" | "file" | "directory";
  url?: string;          // git/url 일 때
  repo?: string;         // github 일 때 (owner/repo)
  installLocation: string;
  // 누락: lastUpdated, autoUpdate, ref, path, sparsePaths
};
```

**디스크 `known_marketplaces.json` vs CLI 비교**: CLI 가 `lastUpdated`, `autoUpdate`, ref/path/sparsePaths 를 모두 누락 → marketplace 탭은 직접 읽기로만 완성 가능.

---

## 3. R12 — Lockfile 호환성 검증

### 3.1 Claude Code 의 락 사용처 (grep 결과)

| 파일 | lockfile 사용 |
|---|---|
| `utils/config.ts` (settings.json) | ✅ proper-lockfile, `${file}.lock` 패턴, onCompromised 핸들러 |
| `history.ts`, `tasks.ts`, `auth.ts`, `cleanup.ts`, `teammateMailbox.ts`, `installer.ts`, `mcp/auth.ts`, `swarm/permissionSync.ts` | ✅ proper-lockfile |
| **`utils/plugins/*` (installed_plugins.json, known_marketplaces.json, blocklist.json)** | **❌ 락 미사용** |
| `utils/plugins/zipCacheAdapters.ts` | atomic rename ("atomic swap") 만 사용 |

### 3.2 Lockfile 파일 형식 검증

`config.ts:1` 에서 발견된 패턴:
```typescript
const lockFilePath = `${file}.lock`
release = lockfile.lockSync(file, { lockfilePath: lockFilePath, onCompromised: ... })
```

실측 lockfile 1개 (다른 출처): `~/.claude/plugins/oh-my-claudecode/.usage-cache.json.lock`
- type: **Regular File** (39 bytes), not directory
- 내용: `{"pid":73846,"timestamp":1775642567513}`

> **이 파일은 OMC 플러그인 자체의 lock** 이지 Claude Code 의 proper-lockfile 이 아님 (proper-lockfile 의 표준 형식은 디렉토리). 플러그인 매니저용 settings.json lockfile 은 mutation 시점에만 생성되고 즉시 cleanup 되므로 idle 상태에서는 디스크에 안 보임.

### 3.3 proper-lockfile 의 실제 디스크 형식

proper-lockfile 표준 동작:
- **Default**: `${file}.lock` 디렉토리 (mkdir 으로 생성, 락 해제 시 rmdir)
- **`{ lockfilePath }` 명시 시**: 그 경로에 디렉토리. 즉 `settings.json.lock/` 디렉토리.

→ **R12 결론**: Swift `flock(2)` 를 써도 proper-lockfile 과 동일 파일 락이 안 됨 (proper-lockfile 은 mkdir 기반). 두 가지 옵션:

**옵션 A (권장)**: Swift 측이 **proper-lockfile 호환 디렉토리 락** 구현
- `settings.json.lock/` 디렉토리를 atomic 하게 mkdir → 성공 시 락 보유, 실패 시 retry
- 락 해제 시 rmdir + 디렉토리 안의 metadata 파일 정리

**옵션 B**: 다른 동시성 전략 — atomic rename + mtime 비교 + retry. settings.json 자체는 적은 mutation 이라 conflict 가능성 낮음.

### 3.4 Plugin manager 파일 (installed_plugins.json 등) 정책

Claude Code 자체가 **lockfile 미사용**이므로:
- 매니저도 락 강제 불필요.
- **atomic rename 으로 충분**: temp 파일에 쓰고 `rename(2)` POSIX atomic 보장.
- 동일 파일시스템 내 rename 만 atomic — `~/.claude` 와 temp 디렉토리가 같은 볼륨이어야 함 (보통 그러함).

---

## 4. PRD 에 반영해야 할 갱신 사항

### 4.1 §1.7 표 수정
- ❌ 삭제: `claude plugin marketplace refresh`
- ✅ 추가: `claude plugin marketplace update [name]` (refresh 역할, 미지정 시 전체)

### 4.2 §6.1 결정 사항 보강
- "Mutation 경로" 행을 다음과 같이 보강:
  > CLI Bridge 1차, **Direct file read 도 항상 필요** (CLI 출력 < disk schema), Direct file mutation 은 enable/disable + autoUpdate toggle + hooks 에 한정

### 4.3 §F2.2 (Add Marketplace) 폼 재설계
- `--ref`, `--auto-update`, `--path` 는 **CLI 미지원**.
- 매니저 흐름: (1) `claude plugin marketplace add <source> --scope <s> [--sparse <paths>]` 로 추가 → (2) settings.json 의 `extraKnownMarketplaces[name].autoUpdate` 또는 source 의 `ref`/`path` 를 매니저가 직접 mutation.
- UI 폼은 그대로 유지하되, 백엔드는 "CLI add → settings.json patch" 2단계 트랜잭션.

### 4.4 §F2.5 autoUpdate 토글
- CLI 미지원 명시 → Direct settings.json mutation 이 1차.

### 4.5 §10.4 File Locking 재작성

```diff
- POSIX `flock(2)` + atomic rename. Lockfile 자체는 `<settings.json>.lock` 같은 형식으로
- Claude Code 의 `proper-lockfile` 규약과 호환.
+ 파일별 정책 분리:
+   - settings.json: Claude Code 가 proper-lockfile (디렉토리 형식) 사용 → Swift 측은
+     `${file}.lock` 을 mkdir 하는 디렉토리 락으로 호환 구현.
+   - installed_plugins.json / known_marketplaces.json / blocklist.json: Claude Code 자체가
+     락 미사용 (atomic rename 만) → 매니저도 atomic rename 으로 충분, 추가 락 불필요.
```

### 4.6 §11.2 fixture 시드 commit
- `spike/cli-fixtures/` 의 캡처 결과를 `Tests/Fixtures/cli/` 로 이동 (M1 시작 시).
- sensitive 가 없는지 검토 (현재 없음 — 모든 데이터가 이미 public marketplace 정보).

### 4.7 §11 신규 테스트 항목
- **Lock interop test**: Swift 매니저가 settings.json 락을 잡고 있는 동안 Node `proper-lockfile` 이 우리 락을 인식하는지, 반대도 마찬가지 — 양방향 테스트.

### 4.8 §15 Open Questions 갱신
- **Q2 marketplace remove cascade**: 미검증 (실제 remove 시도가 destructive 라 dry-run 또는 일회성 테스트 마켓 필요). M0 후속 작업으로.
- **Q3 (다중 머신)**: spike 와 무관, 유지.

### 4.9 §F1 컴포넌트 카운트
- CLI 가 `mcpServers` 만 노출 → commands/agents/skills/hooks/lspServers 카운트는 cache 의 plugin.json + 디렉토리 스캔으로만 가능.
- **새 reader 추가 필요**: `PluginManifestReader` (PRD §6.2 에 이미 있음, 우선순위 ↑).

---

## 5. 산출물 (Deliverables)

`spike/cli-fixtures/`:
- `plugin-list.json` — 26 플러그인 (전체)
- `marketplace-list.json` — 6 마켓 (전체)
- `plugin-help.txt`, `plugin-list-help.txt`, `marketplace-help.txt`, `marketplace-add-help.txt`, `marketplace-update-help.txt`, `marketplace-remove-help.txt`, `install-help.txt`, `uninstall-help.txt`, `update-help.txt`

`spike/lockfile-investigation/`:
- (이 보고서 §3 의 분석 결과만, 별도 파일 없음)

---

## 6. 다음 단계 권장

1. **PRD v2.1 업데이트**: 위 §4 항목들 반영. 특히 §10.4 lockfile 정책, §1.7 명령표.
2. **Cascade 검증 실험** (10분): 일회성 테스트 마켓 (예: 빈 GitHub repo) add → install 1개 → marketplace remove → cascade 거동 관찰.
3. **userConfig 입력 방법 검증** (15분): userConfig 가 있는 플러그인 install 시 stdin 인지 env 인지 확인 — InstallDialog 폼 백엔드 결정에 필요.
4. **PluginCore 첫 코드** (M1 시작): `Schemas/InstalledPluginsV2.swift` + `SchemaRoundtripTests.swift` — 본 spike 의 fixture 로 즉시 라운드트립 검증.

---

**END OF SPIKE REPORT**

---

## 부록 — Q2/Q8 후속 spike 결과 (2026-04-26)

### Q8 — userConfig 입력 채널 (RESOLVED, 비파괴)

`src/utils/plugins/pluginOptionsStorage.ts` 분석 결과:

| 항목 | 결론 |
|---|---|
| install 시점에 userConfig 전달 | ❌ 없음 — install 명령은 그냥 끝남 |
| 수집 시점 | enable 시 + 첫 MCP/LSP 로드 시 (interactive prompt) |
| 저장 (sensitive) | macOS Keychain — `security find-generic-password` (~50-100ms 동기 spawn) |
| 저장 (non-sensitive) | settings.json `pluginConfigs[pluginId].options` |
| Storage key | `pluginId` = `"${name}@${marketplace}"` (`plugin.source`) |
| 읽기 | `loadPluginOptions(pluginId)` — keychain + settings 머지, sensitive 우선 |
| 매니저 함의 | (1) InstallDialog 의 userConfig 폼은 "install → enable → prompt" 흐름의 enable 직후 호출. (2) 매니저 자체 keychain 저장 ❌ — `pluginOptionsStorage` 위임만. (3) 메뉴바 popover 첫 표시 시 keychain spawn 회피 — userConfig 는 detail pane 펼칠 때만 lazy-load. |

### Q2 — Marketplace remove cascade (RESOLVED, 파괴적 검증)

**테스트 절차**:
1. 로컬 `directory` source 마켓 생성 (`/tmp/cc-pm-spike/test-market/`).
2. `claude plugin marketplace add /tmp/cc-pm-spike/test-market` → success, "declared in user settings".
3. `claude plugin install spike-dummy@cc-pm-spike-test --scope user` → success.
4. `claude plugin marketplace remove cc-pm-spike-test` → success.
5. 상태 비교 + cleanup → 사전 상태 정확히 복원.

**Cascade 거동 (실측)**:

| 항목 | remove 시 거동 |
|---|---|
| `known_marketplaces.json` | ✅ entry 자동 제거 |
| `settings.extraKnownMarketplaces[name]` | ✅ entry 자동 제거 |
| `installed_plugins.json[*@market]` | ✅ **모든 소속 플러그인 cascade 자동 제거** |
| `settings.enabledPlugins[*@market]` | ✅ 모든 소속 키 자동 제거 |
| `~/.claude/plugins/cache/<market>/` 디렉토리 | ❌ **orphan 으로 남음** (수동 정리 또는 매니저의 OrphanedCacheDetector 가 노출) |
| `~/.claude/plugins/data/<market>/` | (테스트 케이스에서 data 미생성으로 검증 불가, 매니저 Q 추가) |

**부수 발견 (FYI)**:
- `directory` source 마켓: `~/.claude/plugins/marketplaces/<name>/` 디렉토리 **미생성** — clone 안 함, 원본 경로 그대로 참조. install 시에만 cache 로 복사.
- directory source 로 install 된 플러그인은 `gitCommitSha` 가 없음 (V2 schema 의 optional 필드 — 매니저는 nil 처리 필요).
- `claude plugin validate <path>` 의 schema 가 `marketplace.json` 의 `$schema`/root `description` 키를 거절. 공식 마켓이 사용하는 키도 거절되는 점 — Claude Code schema 와 community marketplace 사이 micro drift 존재 (validate 만 strict, 런타임은 통과).
- `marketplace add <directory>` 가 source type 을 자동 감지 (path → `directory` source).

**PRD 갱신**:
- §F2.3: 임시 채택했던 "명시적 3단계 트랜잭션" 폐기 → **"CLI cascade 위임 + cache cleanup 만 보강"** 으로 단순화 가능.
- §15.Q2: RESOLVED 표시.
- §15.Q8: RESOLVED 표시 — userConfig 흐름 명확화.
- §부록 E: v2.2 entry 추가 권장.
