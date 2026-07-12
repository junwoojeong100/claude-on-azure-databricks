# Claude Code에서 Azure Databricks Claude 사용하기

Azure Databricks는 Claude 모델용 네이티브 Anthropic Messages API를 제공합니다.
Claude Code는 이 API에 직접 연결할 수 있습니다.

```text
Claude Code
  └─ Anthropic Messages API
      └─ https://<workspace-host>/serving-endpoints/anthropic/v1/messages
```

**LiteLLM, 로컬 프록시, 별도 포트, 백그라운드 서비스는 필요하지 않습니다.**

> 최종 검증: 2026-07-12, Claude Code 2.1.207,
> `databricks-claude-opus-4-8`, 단일/다중 턴, high effort,
> `stop_sequences`, 일반 도구 호출.

## 1. 준비 사항

### Azure Databricks

- 지원 리전의 workspace
- 호출 가능한 Databricks-hosted Claude 모델
- 모델 호출 권한이 있는 token
  - 로컬 실습: PAT
  - 운영: 서비스 주체 OAuth M2M 권장
- 일반 endpoint ACL의 `CAN QUERY`
- Foundation Model Unity Catalog 권한 기능 사용 시 대상 `system.ai` 모델의 `EXECUTE`

### Claude Code

```bash
claude --version
```

이 리포의 기본 모델 기준 최소 버전:

| 모델 | Claude Code |
| --- | --- |
| Opus 4.8 | 2.1.154 이상 |
| Fable 5 | 2.1.170 이상 |
| Sonnet 5 | 2.1.197 이상 |

`enforceAvailableModels`로 `/model`의 `Default` 옵션까지 잠그는 동작은 Claude Code
2.1.175 이상에서 지원됩니다. 2.1.154–2.1.174에서도 Opus 4.8 호출은 가능하지만 이
추가 잠금은 무시될 수 있으므로 최신 버전을 권장합니다.

Databricks Anthropic Messages 페이지의 모델 목록은 전체 model catalog보다 늦게
갱신될 수 있습니다. [지원 모델 catalog](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)와
실제 smoke test를 함께 사용하세요.

### 로컬 도구

- macOS/Linux 설치기: `curl`, Python 3
- Windows 설치기: Windows PowerShell 5.1 이상 또는 PowerShell 7

### 프로젝트 `.env`

```bash
cp .env.example .env
chmod 600 .env
```

Windows PowerShell:

```powershell
Copy-Item .env.example .env
icacls .env /inheritance:r /grant:r "${env:USERNAME}:(M)"
```

```dotenv
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<databricks-token>
```

선택:

```dotenv
DATABRICKS_FAST_ENDPOINT=databricks-claude-haiku-4-5
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5"
```

> 설치기의 기본 후보는 Opus/Sonnet/Haiku입니다. Fable 5는 trust and safety 목적으로
> 프롬프트와 응답을 30일 보존하며 일부 경우 사람 검토 대상이 될 수 있으므로, 정책을
> 승인한 경우에만 `DATABRICKS_MODELS`에 `databricks-claude-fable-5`를 추가하세요.

## 2. 자동 설정

자동 설정이 권장 경로입니다. 기존 Claude Code 설정은 백업한 뒤 필요한 항목만
병합합니다.

### 설정 범위 선택

기본 실행은 사용자 전역 `~/.claude/settings.json`을 수정하므로 모든 프로젝트의
Claude Code가 Databricks를 사용합니다. 이 동작을 원하는 경우 다음 기본 명령을
사용합니다.

macOS/Linux:

```bash
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
scripts/setup_claude_code_databricks.sh
```

Windows PowerShell:

```powershell
Remove-Item Env:ANTHROPIC_AUTH_TOKEN, Env:ANTHROPIC_API_KEY `
  -ErrorAction SilentlyContinue
powershell -ExecutionPolicy Bypass `
  -File .\scripts\setup_claude_code_databricks.ps1
```

기존 Anthropic Pro/Max/API 연결과 병행하려면 위 기본 명령 대신 리포 로컬
`settings.local.json`을 선택하세요. 이 리포는 해당 파일과 timestamp 백업을 Git에서
제외합니다.

macOS/Linux:

```bash
mkdir -p .claude
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
CLAUDE_SETTINGS="$PWD/.claude/settings.local.json" \
  scripts/setup_claude_code_databricks.sh
```

Windows PowerShell:

```powershell
Remove-Item Env:ANTHROPIC_AUTH_TOKEN, Env:ANTHROPIC_API_KEY `
  -ErrorAction SilentlyContinue
$LocalSettings = Join-Path (Get-Location) '.claude\settings.local.json'
powershell -ExecutionPolicy Bypass `
  -File .\scripts\setup_claude_code_databricks.ps1 `
  -ClaudeSettings $LocalSettings
```

팀 전체와 공유할 프로젝트 설정은 `.claude/settings.json`을 사용할 수 있지만,
machine-specific helper 경로와 workspace URL이 포함되므로 의도적으로 관리할 때만
커밋하세요. Token 자체는 어느 설정 파일에도 저장하지 않습니다.

스크립트가 수행하는 작업:

1. `.env` 또는 환경변수에서 workspace, token, model 로드
2. Claude Code와 충돌하는 기존 Anthropic credential 확인
3. 네이티브 Anthropic API와 모델 후보 smoke test
4. Token을 사용자 전용 파일에 저장하고 `apiKeyHelper` 생성
5. 선택한 settings 파일(기본 `~/.claude/settings.json`)에 URL과 모델 프리셋 병합
6. `/model`을 검증된 Databricks 모델로 제한
7. 미지원 beta와 hosted `WebSearch` 비활성화
8. 이전 LiteLLM 자동 시작 서비스가 있으면 중지
9. Claude Code를 실제 실행해 종단 간 검증

생성되는 핵심 설정:

```json
{
  "apiKeyHelper": "<token-helper-command>",
  "permissions": {
    "deny": ["WebSearch"]
  },
  "availableModels": [
    "opus",
    "sonnet",
    "haiku",
    "databricks-claude-opus-4-8",
    "databricks-claude-sonnet-5",
    "databricks-claude-haiku-4-5"
  ],
  "enforceAvailableModels": true,
  "env": {
    "ANTHROPIC_BASE_URL": "https://<workspace-host>/serving-endpoints/anthropic",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "900000"
  }
}
```

설치기는 `ANTHROPIC_MODEL`을 설정하지 않습니다. Opus/Sonnet/Haiku 프리셋이
Databricks 모델로 해석되도록 `ANTHROPIC_DEFAULT_*_MODEL`만 설정합니다.
선택한 settings 파일의 `availableModels`와 `enforceAvailableModels`는 현재 사용자의
모델 선택을 제한합니다. 조직 전체에 강제하려면 동일한 두 키를 최고 우선순위의
managed/policy settings에 배포해야 하며, managed 설정이 사용자 목록보다 우선합니다.
`Default` 옵션 잠금은 Claude Code 2.1.175 이상에서만 적용됩니다.

## 3. 자동 설정 결과 확인

```bash
claude --model databricks-claude-opus-4-8 \
  -p "Reply with exactly: DIRECT OK" \
  --output-format json
```

대화형 실행:

```bash
claude
```

실행 중 `/model`을 열면 검증된 Databricks 모델 프리셋을 선택할 수 있습니다.

macOS/Linux에서 base URL 확인:

```bash
SETTINGS_PATH="$HOME/.claude/settings.json" # 로컬 범위는 .claude/settings.local.json
python3 -c \
  'import json, pathlib, sys; p = pathlib.Path(sys.argv[1]); print(json.loads(p.read_text())["env"]["ANTHROPIC_BASE_URL"])' \
  "$SETTINGS_PATH"
```

기대값:

```text
https://<workspace-host>/serving-endpoints/anthropic
```

## 4. 스크립트 없이 수동 설정

### 4.1 현재 셸에서 빠르게 테스트

macOS/Linux:

```bash
unset ANTHROPIC_API_KEY
set -a
. ./.env
set +a
export ANTHROPIC_BASE_URL="${DATABRICKS_HOST%/}/serving-endpoints/anthropic"
export ANTHROPIC_AUTH_TOKEN="$DATABRICKS_TOKEN"
export ANTHROPIC_DEFAULT_OPUS_MODEL="databricks-claude-opus-4-8"
export ANTHROPIC_DEFAULT_SONNET_MODEL="databricks-claude-sonnet-5"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="databricks-claude-haiku-4-5"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

claude --model databricks-claude-opus-4-8 \
  --disallowedTools WebSearch \
  -p "Reply with exactly: DIRECT OK"
```

Windows PowerShell:

```powershell
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
$Config = @{}
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $Config[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
}
$env:ANTHROPIC_BASE_URL = $Config['DATABRICKS_HOST'].TrimEnd('/') + '/serving-endpoints/anthropic'
$env:ANTHROPIC_AUTH_TOKEN = $Config['DATABRICKS_TOKEN']
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = "databricks-claude-opus-4-8"
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "databricks-claude-sonnet-5"
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "databricks-claude-haiku-4-5"
$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"

claude --model databricks-claude-opus-4-8 `
  --disallowedTools WebSearch `
  -p "Reply with exactly: DIRECT OK"
```

이 방식은 현재 셸에만 적용됩니다. 테스트 후 token을 제거합니다.

```bash
unset ANTHROPIC_AUTH_TOKEN DATABRICKS_TOKEN
```

```powershell
Remove-Item Env:ANTHROPIC_AUTH_TOKEN
Remove-Variable Config
```

### 4.2 반복 사용을 위한 영구 설정

PAT를 `settings.json`에 직접 넣지 말고 보호된 파일과 `apiKeyHelper`를 사용하세요.

macOS/Linux helper:

```bash
mkdir -p ~/.claude-databricks
chmod 700 ~/.claude-databricks
cp .env ~/.claude-databricks/.env
chmod 600 ~/.claude-databricks/.env

cat > ~/.claude-databricks/get-token.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
TOKEN_FILE="$(cd "$(dirname "$0")" && pwd)/.env"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DATABRICKS_TOKEN=*) printf "%s" "${line#*=}"; exit 0 ;;
  esac
done < "$TOKEN_FILE"
exit 1
SH
chmod 700 ~/.claude-databricks/get-token.sh

# settings.json에 넣을 절대 경로 확인
printf '%s\n' "$HOME/.claude-databricks/get-token.sh"
```

Windows helper:

```powershell
$StateDir = Join-Path $HOME '.claude-databricks'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Copy-Item .env (Join-Path $StateDir '.env') -Force

@'
$tokenFile = Join-Path $PSScriptRoot '.env'
foreach ($line in Get-Content $tokenFile) {
    if ($line -match '^DATABRICKS_TOKEN=(.*)$') {
        [Console]::Out.Write($Matches[1])
        exit 0
    }
}
exit 1
'@ | Set-Content (Join-Path $StateDir 'get-token.ps1') -Encoding utf8

icacls (Join-Path $StateDir '.env') /inheritance:r /grant:r "${env:USERNAME}:(M)"
icacls (Join-Path $StateDir 'get-token.ps1') /inheritance:r /grant:r "${env:USERNAME}:(M)"
```

그다음 기존 `~/.claude/settings.json`을 **덮어쓰지 말고** 다음 항목을 병합합니다.

macOS/Linux의 `apiKeyHelper`:

```json
{
  "apiKeyHelper": "<위 명령이 출력한 절대 경로>"
}
```

Windows의 `apiKeyHelper`:

```json
{
  "apiKeyHelper": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\<user>\\.claude-databricks\\get-token.ps1\""
}
```

`env`와 `permissions`에는 [자동 설정의 JSON](#2-자동-설정)과 같은 값을 병합합니다.
기존 `permissions.deny` 항목은 보존하면서 `WebSearch`만 추가하세요.
`availableModels`에는 검증한 family alias와 Databricks 모델 ID만 넣고
`enforceAvailableModels`를 `true`로 설정합니다. Fable을 승인하고 실제 검증한
경우에만 `fable`과 `databricks-claude-fable-5`를 추가하세요.

## 5. 모델 전환

```text
/model
```

또는 시작할 때 모델 ID를 지정합니다.

```bash
claude --model databricks-claude-sonnet-5
```

`ANTHROPIC_DEFAULT_HAIKU_MODEL`은 Haiku 프리셋과 세션 제목 생성 같은 경량 작업에
사용됩니다. Deprecated된 `ANTHROPIC_SMALL_FAST_MODEL`은 새로 설정하지 않습니다.

모델 ID는 workspace에서 실제 호출 가능한 값이어야 합니다. 자동 설치기는 각 모델을
먼저 호출하고 검증된 모델만 프리셋에 사용합니다.

## 6. 자주 발생하는 문제

| 증상 | 해결 |
| --- | --- |
| `401 Credential was not sent` | `apiKeyHelper` 경로와 token 파일 확인 |
| 다른 credential이 사용됨 | 셸/프로필의 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY` 제거 후 재실행 |
| beta 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` 확인 |
| `tool type 'web_search_*' is not supported` | `permissions.deny`에 bare `WebSearch` 추가 |
| `/model` 선택 후 모델을 찾지 못함 | Databricks의 실제 endpoint ID와 리전 가용성 확인 |
| `403 ... rate limit of 0` | 모델·리전, cross-Geo, rate limit, 권한, 계정 용량 확인 |
| HTTP 200이지만 `type: "message"`가 없음 | `/serving-endpoints/anthropic/v1/messages` 경로와 Claude 모델 ID를 확인하고 응답 body가 gateway에서 변형되지 않았는지 확인 |
| 이전 포트 4000 프로세스가 남음 | 더 이상 필요 없는 LiteLLM 프로세스의 PID를 확인한 뒤 해당 PID만 종료 |

운영 인증, 모델 fallback, custom base URL 제한, 두 AI Gateway, LiteLLM 마이그레이션은
[Claude Code 상세 참고](claude-code-databricks-reference.md)를 확인하세요.
설정 복원과 credential 제거는
[Databricks 직접 연결 제거](claude-code-databricks-reference.md#10-databricks-직접-연결-제거)를
따르세요.

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Claude Code settings scopes](https://code.claude.com/docs/en/settings#configuration-scopes)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
