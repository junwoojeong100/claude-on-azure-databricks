# Claude Code에서 Azure Databricks Claude 사용하기

Azure Databricks workspace에서 Anthropic Claude 모델을 이미 호출할 수 있다면
`~/.claude/settings.json` 파일 하나로 Claude Code를 연결할 수 있습니다.

```text
Claude Code
  └─ ~/.claude/settings.json
       └─ Azure Databricks /serving-endpoints/anthropic/v1/messages
```

> 최종 검증: 2026-07-13, Claude Code 2.1.207.

## 1. 필요한 값

| 값 | 예 |
| --- | --- |
| Workspace host | `adb-1234567890123456.7.azuredatabricks.net` |
| PAT | 해당 workspace와 모델을 호출할 수 있는 token |

권한:

- Databricks-hosted pay-per-token 모델은 workspace 접근 권한과 유효한 token이 필요합니다.
- Foundation Model Unity Catalog 권한 기능을 사용하면 대상 `system.ai` 모델의
  `EXECUTE`도 필요합니다.
- 직접 만든 custom/external serving endpoint는 `CAN QUERY`도 필요합니다.

### PAT 발급

1. Azure Databricks workspace에서 사용자 이름 → **Settings**
2. **Developer** → **Access tokens** 옆 **Manage**
3. **Generate new token**에서 이름, 유효 기간, API scope 지정
4. 생성 직후 표시되는 token을 안전한 위치에 복사

PAT 메뉴가 없거나 생성이 거부되면 workspace 관리자에게 정책을 확인하세요.

Claude Code는 최신 버전을 권장합니다.

```bash
claude --version
```

Opus 4.8은 2.1.154 이상, Sonnet 5는 2.1.197 이상이 필요합니다.

## 2. Settings 파일 만들기

사용자 전역 Claude Code 설정 디렉터리를 만듭니다.

macOS/Linux:

```bash
mkdir -p "$HOME/.claude"
chmod 700 "$HOME/.claude"
```

Windows PowerShell:

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.claude" | Out-Null
```

`~/.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "WebSearch"
    ]
  },
  "env": {
    "ANTHROPIC_BASE_URL": "https://<workspace-host>/serving-endpoints/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<databricks-pat>",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

바꿀 값:

| Placeholder | 입력할 값 |
| --- | --- |
| `<workspace-host>` | `adb-...azuredatabricks.net` 형식의 host |
| `<databricks-pat>` | 발급받은 PAT |

이 파일에서 모든 설정을 수동으로 처리합니다.

| 설정 | 역할 |
| --- | --- |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` | Databricks가 지원하지 않는 Claude beta 요청 비활성화 |
| `permissions.deny: ["WebSearch"]` | Databricks가 지원하지 않는 hosted `WebSearch` 차단 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `/model`의 `opus`를 Databricks Opus에 연결 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `/model`의 `sonnet`을 Databricks Sonnet에 연결 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `/model`의 `haiku`를 Databricks Haiku에 연결 |

기존 `~/.claude/settings.json`이 있다면 파일 전체를 덮어쓰지 말고 아래 키를 병합합니다.
설정 파일에는 PAT가 들어가므로 파일 권한을 제한합니다.

macOS/Linux:

```bash
chmod 600 "$HOME/.claude/settings.json"
```

Windows PowerShell:

```powershell
icacls "$HOME\.claude\settings.json" `
  /inheritance:r /grant:r "${env:USERNAME}:(M)" | Out-Null
```

현재 리포에서만 Databricks를 사용하려면 같은 JSON을
`.claude/settings.local.json`에 넣습니다. Local settings가 사용자 전역 settings보다
우선합니다.

## 3. 연결 확인

```bash
claude --model opus \
  -p "Reply with exactly: DIRECT OK" \
  --output-format json
```

정상 응답에서 `is_error`는 `false`이고 결과에는 `DIRECT OK`가 포함됩니다.

대화형 실행:

```bash
claude
```

## 4. 모델 선택기

자동 스크립트는 필요하지 않습니다. Claude Code가 settings 파일의 다음 값을 읽어
`/model` alias를 구성합니다.

| 선택 | 실제 Databricks 모델 |
| --- | --- |
| `opus` | `databricks-claude-opus-4-8` |
| `sonnet` | `databricks-claude-sonnet-5` |
| `haiku` | `databricks-claude-haiku-4-5` |

현재 workspace에서 세 모델의 API와 Claude Code alias 호출이 모두 성공하는 것을
확인했습니다.

선택기를 세 alias로 제한하고 싶을 때만 settings 최상위에 다음 항목을 추가합니다.

```json
{
  "availableModels": [
    "opus",
    "sonnet",
    "haiku"
  ]
}
```

Workspace에서 한 모델만 호출할 수 있다면 세 `ANTHROPIC_DEFAULT_*_MODEL` 값을 같은
모델 ID로 지정할 수 있습니다.

## 5. 자주 발생하는 문제

| 증상 | 확인할 항목 |
| --- | --- |
| `401 Credential was not sent` | PAT와 workspace host |
| 다른 provider나 host가 사용됨 | 터미널의 `ANTHROPIC_*`, `CLAUDE_CODE_USE_*` 환경변수 제거 |
| beta 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` |
| `web_search_*` 관련 400 | `permissions.deny`의 `WebSearch` |
| 모델을 찾지 못함 | 실제 모델 ID와 리전 가용성 |
| `403 ... rate limit of 0` | 모델·리전, rate limit, `CAN QUERY`/`EXECUTE`, 계정 용량 |

## 선택: credential 보안 강화

한 파일 방식은 PAT를 평문으로 저장합니다. 보안 요구가 높아지면 다음 공식 인증 방식을
검토하세요.

- [OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)
- [OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
