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
| 모델 ID | `databricks-claude-opus-4-8`, `databricks-claude-sonnet-5`, `databricks-claude-haiku-4-5` |

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
  "availableModels": [
    "opus",
    "sonnet",
    "haiku"
  ],
  "enforceAvailableModels": true,
  "env": {
    "ANTHROPIC_BASE_URL": "https://<workspace-host>/serving-endpoints/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<databricks-pat>",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Opus 4.8 (1M context)",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Sonnet 5 (1M context)",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "Haiku 4.5 (200K context)",
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
| `availableModels` | 메인 세션, subagent, skill, advisor를 검증된 세 alias로 제한 |
| `enforceAvailableModels` | `/model`의 Default도 위 allowlist 안에서 선택 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `/model`의 `opus`를 Databricks Opus에 연결 |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `/model`의 `sonnet`을 Databricks Sonnet에 연결 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `/model`의 `haiku`를 Databricks Haiku에 연결 |
| `ANTHROPIC_DEFAULT_*_MODEL_NAME` | `/model` picker에 모델 이름과 context 크기 표시 |

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
`modelUsage`에는 `databricks-claude-opus-4-8` 계열 모델과
`"contextWindow": 1000000`이 표시됩니다.

대화형 실행:

```bash
claude
```

## 4. 모델 선택기

자동 스크립트는 필요하지 않습니다. Claude Code가 settings 파일의 다음 값을 읽어
`/model` alias를 구성합니다. 기본 JSON은 선택 가능한 모델을 실제 검증한 세 alias로
제한합니다.

| Picker 표시 | 실제 Databricks 모델 |
| --- | --- |
| `Opus 4.8 (1M context)` | `databricks-claude-opus-4-8` |
| `Sonnet 5 (1M context)` | `databricks-claude-sonnet-5` |
| `Haiku 4.5 (200K context)` | `databricks-claude-haiku-4-5` |

현재 workspace에서 세 모델의 API와 Claude Code alias 호출이 모두 성공하는 것을
확인했습니다.

Claude Code 2.1.207은 `fable`과 `best`도 기본 모델 선택지로 제공합니다. 하지만 Fable은
workspace·리전별 가용성을 별도로 확인해야 하고 Databricks에서는 프롬프트와 응답을
trust and safety 목적으로 30일 보존합니다. 따라서 기본 설정은 Fable을 매핑하지 않고
`availableModels`와 `enforceAvailableModels`로 선택을 차단합니다. Fable을 추가하려면
먼저 `databricks-claude-fable-5`의 네이티브 Anthropic API 호출이 성공하는지와 보존
정책을 확인한 뒤 `ANTHROPIC_DEFAULT_FABLE_MODEL`, 해당 `_NAME`, `fable` allowlist를
함께 추가하세요.

Workspace에서 한 모델만 호출할 수 있다면 세 `ANTHROPIC_DEFAULT_*_MODEL` 값을 같은
모델 ID로 지정할 수 있습니다.

## 5. Context window

좌우 방향키로 바꾸는 값은 reasoning effort이며 context window가 아닙니다. 이 가이드의
검증된 mapping에서는 context window를 선택한 모델이 결정하며 별도 settings가 필요하지
않습니다. 실제 적용값은 연결 확인 결과의 `modelUsage.contextWindow`로 확인합니다.

2026-07-13 Azure Databricks 모델 catalog와 Anthropic 모델 문서 기준:

| Databricks 모델 | 모델 context window | 참고 |
| --- | --- | --- |
| `databricks-claude-opus-4-8` | 1M tokens | 현재 기본 Opus |
| `databricks-claude-opus-4-7` | 1M tokens |  |
| `databricks-claude-opus-4-6` | 1M tokens |  |
| `databricks-claude-opus-4-5` | 200K tokens |  |
| `databricks-claude-opus-4-1` | 200K tokens | legacy 모델, Databricks 가용성 재확인 |
| `databricks-claude-sonnet-5` | 1M tokens | 현재 기본 Sonnet |
| `databricks-claude-sonnet-4-6` | 1M tokens |  |
| `databricks-claude-sonnet-4-5` | 200K tokens |  |
| `databricks-claude-sonnet-4` | 200K tokens | legacy 모델, Databricks 가용성 재확인 |
| `databricks-claude-haiku-4-5` | 200K tokens | 현재 기본 Haiku |
| `databricks-claude-fable-5` | 1M tokens | 기본 mapping 제외, 프롬프트·응답 30일 safety 보존 |

현재 Opus와 Sonnet mapping은 이미 1M context를 지원하는 모델을 사용합니다.

위 크기는 Azure Databricks catalog의 모델 설명과 동일 Claude 모델의 공식 Anthropic
model limit을 교차 확인한 값입니다. 모델 ID가 catalog에 있어도 현재 workspace에서
호출 가능하다는 보장은 아니므로 리전, cross-Geo, 권한과 실제 API 응답을 확인해야 합니다.

다만 모델의 context window와 Azure Databricks workspace의 요청 한도는 별개입니다.
공식 Enterprise-tier pay-per-token 표의 Claude 한도는 ITPM 200K, OTPM 20K이고 payload
제한은 4MB입니다. 실제 한도는 workspace platform tier와 별도 설정에 따라 달라질 수
있으므로 1M-token 입력을 한 요청으로 모두 사용할 수 있다고 가정하면 안 됩니다.

## 6. 자주 발생하는 문제

| 증상 | 확인할 항목 |
| --- | --- |
| `401 Credential was not sent` | PAT와 workspace host |
| 다른 provider나 host가 사용됨 | 터미널의 `ANTHROPIC_*`, `CLAUDE_CODE_USE_*` 환경변수 제거 |
| beta 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` |
| `web_search_*` 관련 400 | `permissions.deny`의 `WebSearch` |
| `fable`, `best` 또는 Default가 미검증 모델로 연결됨 | 기본 JSON의 `availableModels`와 `enforceAvailableModels` 병합 여부 |
| 모델을 찾지 못함 | 실제 모델 ID와 리전 가용성 |
| `403 ... rate limit of 0` | 모델·리전, rate limit, `CAN QUERY`/`EXECUTE`, 계정 용량 |

## 선택: credential 보안 강화

한 파일 방식은 legacy PAT를 평문으로 저장합니다. Databricks가 권장하는 OAuth U2M
access token은 1시간 동안 유효하므로, 값을 settings 파일에 한 번 복사하는 방식으로는
지속적으로 사용할 수 없습니다. 매 세션 새 token을 주입하거나, Databricks CLI의
`databricks auth token` 출력에서 `access_token`만 반환하는 helper를 만들고 Claude
Code의 `apiKeyHelper`와 연동해야 합니다. 운영 자동화는 OAuth M2M을 사용하세요.

- [OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)
- [OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)
- [Databricks CLI `auth token`](https://learn.microsoft.com/azure/databricks/dev-tools/cli/reference/auth-commands#databricks-auth-token)
- [Claude Code `apiKeyHelper`](https://code.claude.com/docs/en/llm-gateway-connect#rotate-credentials-with-apikeyhelper)

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks Foundation Model API limits](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/limits)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude context windows](https://platform.claude.com/docs/en/build-with-claude/context-windows)
- [Claude model overview](https://platform.claude.com/docs/en/about-claude/models/overview)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
