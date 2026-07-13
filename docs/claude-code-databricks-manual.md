# Claude Code와 Azure Databricks 수동 연결

이 가이드는 자동 설치 스크립트를 사용하지 않고 Claude Code를 Azure Databricks의
네이티브 Anthropic Messages API에 직접 연결하는 절차입니다.

> 최종 검증: 2026-07-13, Claude Code 2.1.207,
> `databricks-claude-opus-4-8`.

```text
Claude Code
  ├─ settings.json: Databricks URL과 모델 mapping
  └─ apiKeyHelper: 보호된 파일에서 token 출력
       └─ Azure Databricks /serving-endpoints/anthropic/v1/messages
```

수동 설정에 필요한 핵심은 네 가지입니다.

1. `ANTHROPIC_BASE_URL`을 Databricks Anthropic base URL로 지정
2. Token을 settings에 넣지 않고 `apiKeyHelper`로 제공
3. Opus/Sonnet/Haiku alias를 실제 Databricks 모델 ID에 연결
4. 미지원 beta와 hosted `WebSearch` 비활성화

자동 설정을 선호한다면
[Claude Code 연결 가이드의 자동 설정](claude-code-databricks.md#2-자동-설정)을
사용하세요.

## 준비 사항

프로젝트 루트의 `.env`에 다음 값이 있어야 합니다.

```dotenv
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<local-validation-pat>
```

`DATABRICKS_TOKEN`은 빠른 로컬 검증용 PAT(legacy)입니다. 운영 환경에서는 이 가이드의
정적 PAT helper 대신
[OAuth M2M helper](claude-code-databricks-reference.md#5-운영용-oauth-m2m-helper)를
사용하세요.

Workspace URL, 모델 ID, PAT 발급과 권한은
[필요한 접속 정보](claude-code-databricks.md#1-필요한-접속-정보)를 먼저 확인합니다.

## 1. Databricks 네이티브 API 확인

Claude Code 설정 전에 같은 host, token, model로 Anthropic Messages API가 정상
응답하는지 확인합니다. 이 단계가 실패하면 Claude Code settings를 수정하지 말고
workspace 정보, 모델 가용성, 권한부터 해결하세요.

macOS/Linux:

```bash
set -a
. ./.env
set +a

printf 'header = "Authorization: Bearer %s"\n' "$DATABRICKS_TOKEN" |
  curl --config - -sS \
    "$DATABRICKS_HOST/serving-endpoints/anthropic/v1/messages" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
      \"model\": \"$DATABRICKS_SERVING_ENDPOINT\",
      \"max_tokens\": 16,
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: API OK\"}]
    }"
```

Windows PowerShell:

```powershell
$Config = @{}
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $Config[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
}

$Headers = @{
    Authorization       = "Bearer $($Config['DATABRICKS_TOKEN'])"
    'anthropic-version' = '2023-06-01'
}
$Body = @{
    model      = $Config['DATABRICKS_SERVING_ENDPOINT']
    max_tokens = 16
    messages   = @(@{ role = 'user'; content = 'Reply with exactly: API OK' })
} | ConvertTo-Json -Depth 5
$HostUrl = $Config['DATABRICKS_HOST'].TrimEnd('/')

(Invoke-RestMethod `
    "$HostUrl/serving-endpoints/anthropic/v1/messages" `
    -Method Post `
    -Headers $Headers `
    -ContentType 'application/json' `
    -Body $Body).type
```

정상 응답에는 `"type": "message"`가 포함되며 PowerShell 출력은 `message`입니다.

## 2. Settings 범위 선택과 백업

| 범위 | 파일 | 사용 시점 |
| --- | --- | --- |
| 사용자 전역 | `~/.claude/settings.json` | 모든 프로젝트에서 Databricks 사용 |
| 현재 리포만 | `.claude/settings.local.json` | 기존 Anthropic/Foundry 연결과 프로젝트별 병행 |

기존 settings 파일을 덮어쓰지 말고 먼저 백업합니다.

macOS/Linux:

```bash
SETTINGS_PATH="$HOME/.claude/settings.json"
# 현재 리포만 설정하려면:
# SETTINGS_PATH="$PWD/.claude/settings.local.json"

mkdir -p "$(dirname "$SETTINGS_PATH")"
if [ -f "$SETTINGS_PATH" ]; then
  cp "$SETTINGS_PATH" "$SETTINGS_PATH.bak.$(date +%Y%m%d%H%M%S)"
fi
```

Windows PowerShell:

```powershell
$SettingsPath = Join-Path $HOME '.claude\settings.json'
# 현재 리포만 설정하려면:
# $SettingsPath = Join-Path (Get-Location) '.claude\settings.local.json'

$SettingsDirectory = Split-Path $SettingsPath -Parent
New-Item -ItemType Directory -Force -Path $SettingsDirectory | Out-Null
if (Test-Path $SettingsPath) {
    Copy-Item $SettingsPath "$SettingsPath.bak.$(Get-Date -Format yyyyMMddHHmmss)"
}
```

## 3. Credential helper 만들기

### macOS/Linux

Token 파일과 helper는 사용자만 읽고 실행할 수 있게 제한합니다.

```bash
mkdir -p "$HOME/.claude-databricks"
chmod 700 "$HOME/.claude-databricks"
cp .env "$HOME/.claude-databricks/.env"
chmod 600 "$HOME/.claude-databricks/.env"

cat > "$HOME/.claude-databricks/get-token.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
TOKEN_FILE="$(cd "$(dirname "$0")" && pwd)/.env"

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DATABRICKS_TOKEN=*)
      value="${line#*=}"
      value="${value%$'\r'}"
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      printf "%s" "$value"
      exit 0
      ;;
  esac
done < "$TOKEN_FILE"

echo "DATABRICKS_TOKEN is missing from $TOKEN_FILE" >&2
exit 1
SH

chmod 700 "$HOME/.claude-databricks/get-token.sh"
printf '%s\n' "$HOME/.claude-databricks/get-token.sh"
```

마지막 명령이 출력한 절대 경로를 `apiKeyHelper`에 사용합니다.

### Windows PowerShell

```powershell
$StateDir = Join-Path $HOME '.claude-databricks'
$TokenFile = Join-Path $StateDir '.env'
$HelperPath = Join-Path $StateDir 'get-token.ps1'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Copy-Item .env $TokenFile -Force

@'
$tokenFile = Join-Path $PSScriptRoot '.env'
foreach ($line in Get-Content $tokenFile) {
    if ($line -match '^DATABRICKS_TOKEN=(.*)$') {
        $value = $Matches[1].Trim().Trim('"').Trim("'")
        [Console]::Out.Write($value)
        exit 0
    }
}
Write-Error "DATABRICKS_TOKEN is missing from $tokenFile"
exit 1
'@ | Set-Content $HelperPath -Encoding utf8

icacls $TokenFile /inheritance:r /grant:r "${env:USERNAME}:(M)" | Out-Null
icacls $HelperPath /inheritance:r /grant:r "${env:USERNAME}:(M)" | Out-Null

$HelperCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`""
$HelperCommand | ConvertTo-Json
```

마지막 명령이 출력한 JSON string을 `apiKeyHelper` 값으로 사용합니다. 이 출력에는
Windows 경로와 내부 따옴표에 필요한 escape가 포함됩니다.

## 4. Claude Code settings 병합

선택한 settings 파일이 없으면 다음 JSON으로 새로 만듭니다. 기존 파일이 있다면 다른
설정을 보존하면서 같은 키를 병합하세요.

아래 예시는 **하나의 검증된 모델만으로 시작하는 최소 설정**입니다. Claude Code 내부의
Opus/Sonnet/Haiku 작업이 모두 같은 Databricks 모델로 라우팅됩니다.

```json
{
  "apiKeyHelper": "<absolute-helper-command>",
  "permissions": {
    "deny": [
      "WebSearch"
    ]
  },
  "availableModels": [
    "opus",
    "sonnet",
    "haiku",
    "databricks-claude-opus-4-8"
  ],
  "enforceAvailableModels": true,
  "env": {
    "ANTHROPIC_BASE_URL": "<workspace-url>/serving-endpoints/anthropic",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-opus-4-8",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "900000"
  }
}
```

`<absolute-helper-command>`:

```text
macOS/Linux:
/Users/<user>/.claude-databricks/get-token.sh

Windows:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<user>\.claude-databricks\get-token.ps1"
```

macOS/Linux는 placeholder 안의 문자열만 절대 경로로 바꿉니다. Windows는
`"<absolute-helper-command>"` 전체를 `ConvertTo-Json` 출력으로 교체합니다.

`<workspace-url>`에는 `https://`를 포함한 전체 `DATABRICKS_HOST` 값을 넣습니다. 최종
값은 다음 형식이어야 합니다.

```text
https://adb-1234567890123456.7.azuredatabricks.net/serving-endpoints/anthropic
```

Sonnet과 Haiku 모델도 각각 API 검증에 성공했다면 다음 값으로 바꾸고
`availableModels`에도 두 모델 ID를 추가합니다.

```json
{
  "availableModels": [
    "opus",
    "sonnet",
    "haiku",
    "databricks-claude-opus-4-8",
    "databricks-claude-sonnet-5",
    "databricks-claude-haiku-4-5"
  ],
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5"
  }
}
```

이 두 번째 JSON은 전체 settings가 아니라 변경할 부분만 보여줍니다. 기존
`ANTHROPIC_BASE_URL`, beta, helper TTL, `permissions`, `apiKeyHelper`를 유지하세요.

중요:

- Token을 `settings.json`의 `ANTHROPIC_AUTH_TOKEN`이나 `ANTHROPIC_API_KEY`에 넣지 않습니다.
- `ANTHROPIC_MODEL`을 설정하지 않습니다.
- 기존 `permissions.deny` 값은 보존하고 `WebSearch`만 추가합니다.
- 사용자 settings의 모델 목록은 로컬 실수 방지용입니다. 조직 정책은 managed settings로
  배포합니다.

## 5. 충돌하는 기존 설정 제거

프로세스 환경변수는 settings 파일보다 우선합니다. Claude Code를 시작하기 전에 기존
Anthropic credential, model override, 다른 provider selector를 제거합니다.

macOS/Linux:

```bash
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
unset ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
unset ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL
unset CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_BEDROCK
unset CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_MANTLE
unset CLAUDE_CODE_USE_ANTHROPIC_AWS
```

Windows PowerShell:

```powershell
Remove-Item `
    Env:ANTHROPIC_BASE_URL, Env:ANTHROPIC_AUTH_TOKEN, Env:ANTHROPIC_API_KEY, `
    Env:ANTHROPIC_MODEL, Env:ANTHROPIC_SMALL_FAST_MODEL, `
    Env:ANTHROPIC_DEFAULT_OPUS_MODEL, Env:ANTHROPIC_DEFAULT_SONNET_MODEL, `
    Env:ANTHROPIC_DEFAULT_HAIKU_MODEL, Env:ANTHROPIC_DEFAULT_FABLE_MODEL, `
    Env:CLAUDE_CODE_USE_FOUNDRY, Env:CLAUDE_CODE_USE_BEDROCK, `
    Env:CLAUDE_CODE_USE_VERTEX, Env:CLAUDE_CODE_USE_MANTLE, `
    Env:CLAUDE_CODE_USE_ANTHROPIC_AWS `
    -ErrorAction SilentlyContinue
```

사용자 전역 settings와 리포 로컬 settings에 같은 키가 중복되어 있거나 기존 provider를
동시에 유지해야 한다면
[격리된 설정 디렉터리](claude-code-databricks-reference.md#기존-anthropic-api-credential과-병행)를
사용하세요.

## 6. 연결 확인

먼저 settings 오류를 확인합니다.

```bash
claude doctor
```

그다음 Databricks 모델을 명시해 종단 간 호출을 실행합니다.

```bash
claude --model databricks-claude-opus-4-8 \
  -p "Reply with exactly: MANUAL OK" \
  --output-format json
```

정상 응답에서 `is_error`는 `false`이고 결과에는 `MANUAL OK`가 포함됩니다.

대화형 실행:

```bash
claude
```

`/model`에서 설정한 Databricks 모델과 Opus/Sonnet/Haiku alias를 확인합니다.

## 7. 설정 제거

수동 설정을 제거할 때는 다음 순서를 사용합니다.

1. Claude Code 종료
2. 백업한 settings 파일 복원
3. `~/.claude-databricks/.env`와 `get-token.*` 제거
4. Workspace를 유지한다면 사용한 PAT를 Databricks UI에서 폐기

전체 복원 명령은
[Databricks 직접 연결 제거](claude-code-databricks-reference.md#10-databricks-직접-연결-제거)를
확인하세요.
