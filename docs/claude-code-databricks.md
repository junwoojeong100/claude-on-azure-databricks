# Claude Code를 Azure Databricks Claude에 직접 연결하기

Azure Databricks workspace에서 Anthropic Claude 모델을 호출할 수 있다면 Claude Code를
Databricks의 네이티브 Anthropic Messages API에 직접 연결할 수 있습니다.
이 문서는 Databricks 흐름의 1단계입니다. 검증 후 기존 gateway로 중앙화하려면
[기존 LiteLLM 서버 Databricks 연결 가이드](existing-litellm-databricks.md)로
진행합니다.

```text
Claude Code
  └─ https://<workspace-host>/serving-endpoints/anthropic/v1/messages
```

권장 순서는 다음과 같습니다.

1. Databricks API를 직접 호출해 URL, credential, 모델 ID 검증
2. 같은 값을 임시 환경변수로 Claude Code에서 검증
3. Opus·Sonnet·Haiku 다중 모델 설정을 파일에 저장
4. 필요한 경우 OAuth 자동 갱신 또는 단일 모델 최소 설정으로 조정

> 공식 문서 확인: 2026-07-27. Opus 5는 Claude Code 2.1.219 이상, Sonnet 5는
> 2.1.197 이상이 필요합니다.

## 1. 준비 사항

| 값 | 예 |
| --- | --- |
| Workspace host | `adb-1234567890123456.7.azuredatabricks.net` |
| Databricks credential | 빠른 검증은 PAT, 장기 사용자 인증은 OAuth U2M |
| 호출 가능한 모델 ID 하나 | `databricks-claude-opus-5` |
| 로컬 도구 | Git, Python 3.10 이상, 최신 Claude Code |

첫 API 검증에는 모델 하나만 선택하세요. 아래 예시는 현재 기본 모델인 Opus 5를
사용합니다.

권한:

- Databricks-hosted pay-per-token 모델은 workspace 접근 권한과 유효한 token이 필요합니다.
- Foundation Model Unity Catalog 권한 기능을 사용하면 대상 `system.ai` 모델의
  `EXECUTE`도 필요합니다.
- 직접 만든 custom 또는 external serving endpoint는 endpoint ACL의 `CAN QUERY`도
  필요합니다.

Claude Code는 최신 버전을 권장합니다.

```bash
claude --version
```

### 빠른 검증용 PAT 발급

1. Azure Databricks workspace에서 사용자 이름 → **Settings**
2. **Developer** → **Access tokens** 옆 **Manage**
3. **Generate new token**에서 이름, 유효 기간, 필요한 API scope 지정
4. 생성 직후 표시되는 token을 안전한 위치에 복사

PAT 메뉴가 없거나 생성이 거부되면 workspace 관리자에게 정책을 확인하세요.

## 2. Databricks API부터 검증

Claude Code 설정을 만들기 전에 네이티브 Anthropic API를 직접 호출합니다. 이 단계가
성공하면 workspace URL, credential, 모델 ID를 독립적으로 검증한 것입니다.

### macOS, Linux, WSL

```bash
export ANTHROPIC_BASE_URL="https://<workspace-host>/serving-endpoints/anthropic"
export ANTHROPIC_AUTH_TOKEN="<databricks-token>"
export DATABRICKS_MODEL="databricks-claude-opus-5"

curl -sS "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{\"model\":\"$DATABRICKS_MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}"
```

### Windows PowerShell

```powershell
$env:ANTHROPIC_BASE_URL = 'https://<workspace-host>/serving-endpoints/anthropic'
$env:ANTHROPIC_AUTH_TOKEN = '<databricks-token>'
$env:DATABRICKS_MODEL = 'databricks-claude-opus-5'

$Body = @{
    model = $env:DATABRICKS_MODEL
    max_tokens = 16
    messages = @(
        @{
            role = 'user'
            content = 'Reply with exactly: OK'
        }
    )
} | ConvertTo-Json -Depth 4

Invoke-RestMethod `
    -Method Post `
    -Uri "$env:ANTHROPIC_BASE_URL/v1/messages" `
    -Headers @{
        Authorization = "Bearer $env:ANTHROPIC_AUTH_TOKEN"
        'anthropic-version' = '2023-06-01'
    } `
    -ContentType 'application/json' `
    -Body $Body
```

성공 응답의 최상위 `type`은 `message`입니다. 실패하면
[문제 해결](#7-문제-해결)에서 HTTP 상태를 먼저 확인하세요.

## 3. Claude Code에서 임시 검증

Databricks API 호출이 성공한 같은 터미널에서 Claude Code를 실행합니다.

`~/.claude/settings.json`에 기존 Foundry 또는 gateway route가 있으면 그 `env` 값이
shell 환경변수보다 우선합니다. `/status`에 다른 base URL이 표시되면 설정 파일을
백업한 뒤 기존 `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` 또는 `apiKeyHelper`,
model 값을 제거하거나 Databricks 값으로 바꾸고 Claude Code를 다시 시작합니다.

### macOS, Linux, WSL

```bash
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

claude --model "databricks-claude-opus-5[1m]" \
  -p "Reply with exactly: CLAUDE CODE OK" \
  --output-format json
```

### Windows PowerShell

```powershell
$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = '1'

claude --model 'databricks-claude-opus-5[1m]' `
    -p 'Reply with exactly: CLAUDE CODE OK' `
    --output-format json
```

`is_error`가 `false`이고 `modelUsage`에 `databricks-claude-opus-5`가 표시되어야
합니다. 이 모델의 `contextWindow`는 `1000000`이어야 합니다.

대화형으로 실행한 뒤 `/status`를 열어 실제 routing도 확인합니다.

```bash
claude
```

- `Anthropic base URL`: `https://<workspace-host>/serving-endpoints/anthropic`
- `Auth token`: `ANTHROPIC_AUTH_TOKEN`

다른 provider나 claude.ai login이 사용된다면 `/logout`을 실행하거나 터미널의
`ANTHROPIC_*`, `CLAUDE_CODE_USE_*` 환경변수 충돌을 제거하세요.

## 4. 다중 모델 영구 설정

임시 검증이 성공한 같은 터미널에서 리포의 설정 도구를 실행합니다.

macOS, Linux, WSL:

```bash
python3 scripts/configure_claude_code.py
```

Windows PowerShell:

```powershell
py -3 scripts\configure_claude_code.py
```

도구는 앞 단계의 `ANTHROPIC_BASE_URL`과 `ANTHROPIC_AUTH_TOKEN`을 읽고 다음 작업을
수행합니다.

1. 기존 `~/.claude/settings.json`을 `.bak.<timestamp>`로 백업하고 최신 1개만 유지
2. unrelated settings를 유지하면서 Databricks routing과 picker 키만 병합
3. 충돌하는 provider routing 키 제거
4. macOS/Linux/WSL은 `0600`, Windows는 `icacls`로 현재 사용자만 수정하도록 제한

현재 프로젝트에만 적용하려면 `--scope project`를 추가합니다. 이 경우
`.claude/settings.local.json`에 저장됩니다.

도구가 생성하는 기본 설정은 `/model` picker에 최신 Opus와 Sonnet 각 2개, Haiku 1개를
처음부터 표시합니다.

```json
{
  "permissions": {
    "deny": [
      "WebSearch"
    ]
  },
  "model": "databricks-claude-opus-5[1m]",
  "env": {
    "ANTHROPIC_BASE_URL": "https://<workspace-host>/serving-endpoints/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<databricks-token>",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-5[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Opus 5 (1M context)",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "Custom Opus model (1M context)",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "databricks-claude-opus-4-8[1m]",
    "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "Opus 4.8 (1M context)",
    "ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION": "Custom Opus model (1M context)",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Sonnet 5 (1M context)",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION": "Custom Sonnet model (1M context)",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "databricks-claude-sonnet-4-6[1m]",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Sonnet 4.6 (1M context)",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Custom Sonnet model (1M context)",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "Haiku 4.5 (200K context)",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION": "Custom Haiku model (200K context)",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

Claude Code가 이름을 지정할 수 있는 custom picker 항목은 하나입니다. 따라서 이 구성은
`fable` picker 자리를 Opus 4.8에 사용하고, custom option을 Sonnet 4.6에 사용합니다.
`/model fable`을 입력하면 실제 Fable 5가 아니라 Opus 4.8이 선택됩니다.

| Picker 모델 | Claude Code 선택값 | Databricks 모델 ID | `contextWindow` |
| --- | --- | --- | --- |
| `Opus 5 (1M context)` | `opus` | `databricks-claude-opus-5` | 1,000,000 |
| `Opus 4.8 (1M context)` | `fable` | `databricks-claude-opus-4-8` | 1,000,000 |
| `Sonnet 5 (1M context)` | `sonnet` | `databricks-claude-sonnet-5` | 1,000,000 |
| `Sonnet 4.6 (1M context)` | custom option | `databricks-claude-sonnet-4-6` | 1,000,000 |
| `Haiku 4.5 (200K context)` | `haiku` | `databricks-claude-haiku-4-5` | 200,000 |

Workspace에서 일부 모델만 호출할 수 있다면 해당 `ANTHROPIC_DEFAULT_*` 또는
`ANTHROPIC_CUSTOM_MODEL_OPTION*` 항목만 제거하세요. 다른 사용자의 설정에는 영향을 주지
않습니다.

Claude Code를 완전히 종료한 뒤 다시 시작해야 picker 항목이 갱신됩니다. JSON을
수동으로 관리하려면 기존 파일 전체를 덮어쓰지 말고 위 키만 병합하세요.

설정 후 다섯 모델을 한 번에 확인합니다.

```bash
models=(
  "databricks-claude-opus-5[1m]"
  "databricks-claude-opus-4-8[1m]"
  "databricks-claude-sonnet-5[1m]"
  "databricks-claude-sonnet-4-6[1m]"
  "databricks-claude-haiku-4-5"
)

for model in "${models[@]}"; do
  claude --model "$model" \
    -p "Reply with exactly: ${model} OK" \
    --output-format json
done
```

Windows PowerShell:

```powershell
$models = @(
  'databricks-claude-opus-5[1m]'
  'databricks-claude-opus-4-8[1m]'
  'databricks-claude-sonnet-5[1m]'
  'databricks-claude-sonnet-4-6[1m]'
  'databricks-claude-haiku-4-5'
)

$models | ForEach-Object {
  claude --model $_ `
    -p "Reply with exactly: $_ OK" `
    --output-format json
}
```

다섯 응답 모두 `is_error`가 `false`여야 합니다. `modelUsage`에는 선택한 모델에 대응하는
`databricks-claude-*` ID가 표시됩니다.

> **완료 기준:** 새 Claude Code session의 `/status`에 Databricks Anthropic base URL이
> 표시되고, 등록한 모델의 테스트 응답이 모두 성공합니다.

## 5. 선택: 단일 모델 최소 설정

특정 모델만 허용하거나 picker mapping이 필요하지 않은 환경에서는 다음 최소 설정을
사용할 수 있습니다.

```json
{
  "permissions": {
    "deny": [
      "WebSearch"
    ]
  },
  "model": "databricks-claude-opus-5[1m]",
  "env": {
    "ANTHROPIC_BASE_URL": "https://<workspace-host>/serving-endpoints/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<databricks-token>",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

## 6. Context window과 요청 한도

`[1m]`은 custom `ANTHROPIC_BASE_URL` 뒤에서 Claude Code가 1M context를 관리하도록 하는
selector입니다. Claude Code는 selector를 제거한 Databricks 모델 ID를 API에 전송합니다.

| Databricks 모델 | 모델 context window |
| --- | --- |
| `databricks-claude-opus-5` | 1M tokens |
| `databricks-claude-opus-4-8` | 1M tokens |
| `databricks-claude-opus-4-7` | 1M tokens |
| `databricks-claude-opus-4-6` | 1M tokens |
| `databricks-claude-opus-4-5` | 200K tokens |
| `databricks-claude-sonnet-5` | 1M tokens |
| `databricks-claude-sonnet-4-6` | 1M tokens |
| `databricks-claude-sonnet-4-5` | 200K tokens |
| `databricks-claude-haiku-4-5` | 200K tokens |

모델 context window와 Azure Databricks workspace 요청 한도는 별개입니다. 공식
Enterprise-tier pay-per-token 표의 Claude 한도는 ITPM 200K, OTPM 20K이고 payload
제한은 4MB입니다. 따라서 1M-token 입력을 한 요청에서 모두 사용할 수 있다고 가정하면
안 됩니다.

## 7. 문제 해결

| 단계 또는 증상 | 확인할 항목 |
| --- | --- |
| 직접 API 호출도 `401` | PAT/OAuth token, workspace host, token이 같은 workspace용인지 |
| 직접 API는 성공하고 Claude Code만 실패 | `/status`, 환경변수 충돌, Claude Code 버전 |
| beta 관련 `400` | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` |
| `web_search_*` 관련 `400` | `permissions.deny`의 `WebSearch` |
| `contextWindow`가 `200000` | 1M 모델 값 끝의 `[1m]`과 Claude Code 재시작 |
| 모델을 찾지 못함 | 실제 모델 ID와 workspace 리전 가용성 |
| `403 ... rate limit of 0` | 모델·리전, cross-Geo, `CAN QUERY`/`EXECUTE`, 계정 용량 |
| 일반적인 사용량 초과 `429` | ITPM, OTPM, QPH와 재시도 간격 |

## 8. PAT 대신 OAuth U2M

Databricks OAuth U2M은 access token을 자동으로 갱신할 수 있습니다. 이 리포는
Databricks CLI의 token cache를 Claude Code `apiKeyHelper`와 연결하는 helper를
제공합니다.

`databricks auth` 명령이 없다면 먼저
[Databricks CLI](https://learn.microsoft.com/azure/databricks/dev-tools/cli/install)를
설치하세요.

### 1. Databricks CLI 로그인

```bash
databricks auth login \
  --host "https://<workspace-host>" \
  --profile claude-code
```

브라우저 로그인을 마치면 `claude-code` profile에 OAuth U2M 인증 정보가 저장됩니다.

### 2. OAuth 다중 모델 설정

macOS, Linux, WSL:

```bash
export DATABRICKS_HOST="https://<workspace-host>"
python3 scripts/configure_claude_code.py --auth oauth
```

Windows PowerShell:

```powershell
$env:DATABRICKS_HOST = 'https://<workspace-host>'
py -3 scripts\configure_claude_code.py --auth oauth
```

설정 도구는 기존 파일을 백업하고 PAT를 제거한 뒤 OS에 맞는 `apiKeyHelper`,
`DATABRICKS_CONFIG_PROFILE=claude-code`, 다중 모델 picker를 병합합니다.

### 3. Helper 직접 확인

macOS, Linux, WSL:

```bash
DATABRICKS_CONFIG_PROFILE=claude-code \
  scripts/get_databricks_oauth_token.sh
```

Windows PowerShell:

```powershell
$env:DATABRICKS_CONFIG_PROFILE = 'claude-code'
.\scripts\Get-DatabricksOAuthToken.ps1
```

두 helper 모두 현재 access token만 stdout으로 출력합니다. Claude Code는 helper 결과를
기본 5분 동안 cache하고 `401` 응답을 받으면 다시 실행합니다. Bash helper는 token JSON을
읽기 위해 Python 3을 사용합니다.

운영 자동화는 사용자 브라우저 로그인이 필요한 U2M 대신 OAuth M2M을 사용하세요. M2M은
조직의 credential provider나 vault에서 access token을 반환하는 별도 `apiKeyHelper`와
연동해야 합니다.

## 9. VS Code extension 사용 시

이 문서의 기본 경로는 Claude Code CLI입니다. VS Code extension은 자체 로그인 확인 전에
credential을 읽어야 하므로 VS Code 사용자 settings의 `claudeCode.environmentVariables`에도
값을 설정하는 것이 가장 확실합니다.

```json
{
  "claudeCode.environmentVariables": [
    {
      "name": "ANTHROPIC_BASE_URL",
      "value": "https://<workspace-host>/serving-endpoints/anthropic"
    },
    {
      "name": "ANTHROPIC_AUTH_TOKEN",
      "value": "<databricks-token>"
    },
    {
      "name": "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
      "value": "1"
    }
  ]
}
```

`~/.claude/settings.json`의 `apiKeyHelper`는 extension이 실행한 Claude Code process에는
전달되지만 extension 자체의 시작 전 로그인 확인에는 사용되지 않습니다. PAT를 저장하지
않는 extension 배포는 조직에서 갱신된 credential을
`claudeCode.environmentVariables`에 공급하는 별도 관리 방식이 필요합니다.

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks Foundation Model API limits](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/limits)
- [Azure Databricks OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)
- [Databricks CLI `auth token`](https://learn.microsoft.com/azure/databricks/dev-tools/cli/reference/auth-commands#databricks-auth-token)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
