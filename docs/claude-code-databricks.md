# Claude Code에서 Azure Databricks Claude 사용하기

이 가이드는 **Azure Databricks workspace와 호출 가능한 Anthropic Claude 모델이 이미
준비된 상태**에서 시작합니다. 새 workspace를 만들 필요는 없습니다.

```text
Claude Code
  └─ Anthropic Messages API
      └─ https://<workspace-host>/serving-endpoints/anthropic/v1/messages
```

Claude Code는 Databricks의 네이티브 Anthropic Messages API에 직접 연결됩니다.
**LiteLLM, 로컬 프록시, 별도 포트, 백그라운드 서비스는 필요하지 않습니다.**

> 최종 검증: 2026-07-13, Claude Code 2.1.207,
> `databricks-claude-opus-4-8`, 단일/다중 턴, high effort,
> `stop_sequences`, 일반 도구 호출.

## 1. 필요한 접속 정보

다음 세 값을 workspace 관리자에게 받거나 직접 확인합니다.

| 값 | 설명 | 예 |
| --- | --- | --- |
| `DATABRICKS_HOST` | Per-workspace URL 전체 | `https://adb-1234567890123456.7.azuredatabricks.net` |
| `DATABRICKS_SERVING_ENDPOINT` | 실제 호출 가능한 Claude 모델 ID | `databricks-claude-opus-4-8` |
| `DATABRICKS_TOKEN` | 자동 설치기가 사용할 credential | 빠른 로컬 검증용 PAT(legacy). 운영 OAuth M2M은 별도 helper 사용 |

Workspace URL은 Azure portal의 Databricks 리소스에서 **Launch Workspace** 옆 URL을
복사할 수 있습니다. 모델 ID는 Databricks workspace의 **Serving** 화면과
[지원 모델 catalog](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)에서
확인합니다.

### 권한

- 사전 구성된 Databricks-hosted pay-per-token 모델: workspace 접근 권한과 유효한 API
  token. Foundation Model Unity Catalog 권한 기능을 사용하면 대상 `system.ai` 모델의
  `EXECUTE`도 필요합니다.
- 직접 만든 custom/external serving endpoint: endpoint ACL의 `CAN QUERY`도 필요합니다.

Azure 구독 Owner/Contributor와 Databricks workspace 권한은 별개입니다. Workspace가
이미 있어도 현재 사용자가 모델을 호출할 권한이 없으면 `401` 또는 `403`이 발생합니다.

### 빠른 로컬 검증용 PAT 발급

PAT 인증은 legacy이며 Databricks는 가능한 경우 OAuth를 권장합니다. 이 가이드는 빠른
로컬 검증을 위해 PAT를 사용할 수 있게 안내하고, 장기 운영은
[서비스 주체 OAuth M2M helper](claude-code-databricks-reference.md#5-운영용-oauth-m2m-helper)를
사용합니다.

PAT가 필요하다면 Azure Databricks workspace UI에서 발급합니다.

1. 상단 사용자 이름 → **Settings**
2. **Developer** → **Access tokens** 옆 **Manage**
3. **Generate new token**을 선택하고 이름, 짧은 유효 기간, 조직 정책에 맞는 API scope
   지정
4. 생성 직후 표시되는 token 값을 안전한 임시 위치에 복사

**Access tokens** 메뉴가 없거나 생성이 거부되면 workspace 관리자가 PAT 사용을
비활성화했거나 최대 수명을 제한했을 수 있습니다. 이 경우 workspace 관리자에게 PAT
정책과 OAuth 사용 방법을 확인하세요.

Databricks CLI가 설치되어 있고 OAuth 사용자 로그인이 허용된다면 다음 명령으로도 PAT를
만들 수 있습니다.

```text
databricks auth login --host "https://<workspace-host>" --profile claude-databricks
databricks tokens create --profile claude-databricks --comment "claude-code-databricks" --lifetime-seconds 7776000
```

두 명령에 같은 profile을 지정해야 다른 workspace에 token을 만드는 실수를 피할 수
있습니다. `token_value`는 다시 표시되지 않으므로 즉시 안전하게 보관합니다.

### 로컬 도구

- 최신 Claude Code: `claude --version`
- macOS/Linux 설치기: `curl`, Python 3
- Windows 설치기: Windows PowerShell 5.1 이상 또는 PowerShell 7

Opus 4.8은 Claude Code 2.1.154 이상, Fable 5는 2.1.170 이상, Sonnet 5는 2.1.197
이상이 필요합니다. 최신 버전 사용을 권장합니다.

### 프로젝트 `.env`

macOS/Linux:

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks
cp .env.example .env
chmod 600 .env
```

Windows PowerShell:

```powershell
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
Set-Location claude-on-azure-databricks
Copy-Item .env.example .env
icacls .env /inheritance:r /grant:r "${env:USERNAME}:(M)"
```

`.env`:

```dotenv
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<databricks-token>
```

이 `.env` 기반 자동 설정은 빠른 PAT 검증 경로입니다. 운영 OAuth M2M에서는
`DATABRICKS_TOKEN`을 장기 저장하지 말고
[OAuth M2M helper](claude-code-databricks-reference.md#5-운영용-oauth-m2m-helper)를
구성하세요.

여러 Claude 모델을 사용할 때만 후보를 추가합니다.

```dotenv
DATABRICKS_FAST_ENDPOINT=databricks-claude-haiku-4-5
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5"
```

설치기는 후보 모델을 실제로 호출한 뒤 성공한 모델만 Claude Code 프리셋에 연결합니다.

## 2. 자동 설정

자동 설정이 권장 경로입니다. 기존 Claude Code 설정을 timestamp 백업한 뒤 필요한
항목만 병합하고, token 자체는 settings 파일에 저장하지 않습니다.

### 사용자 전역 설정

모든 프로젝트의 Claude Code가 Databricks를 사용하게 하려면 기본 명령을 실행합니다.

macOS/Linux:

```bash
scripts/setup_claude_code_databricks.sh
```

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\scripts\setup_claude_code_databricks.ps1
```

기본 대상은 `~/.claude/settings.json`입니다. `CLAUDE_CONFIG_DIR`가 설정되어 있으면 그
디렉터리의 `settings.json`을 사용합니다.

### 현재 리포에서만 사용

기존 Anthropic Pro/Max/API나 다른 provider 설정을 유지하려면 리포 로컬
`.claude/settings.local.json`을 선택할 수 있습니다.

macOS/Linux:

```bash
mkdir -p .claude
CLAUDE_SETTINGS="$PWD/.claude/settings.local.json" \
  scripts/setup_claude_code_databricks.sh
```

Windows PowerShell:

```powershell
$LocalSettings = Join-Path (Get-Location) '.claude\settings.local.json'
powershell -ExecutionPolicy Bypass `
  -File .\scripts\setup_claude_code_databricks.ps1 `
  -ClaudeSettings $LocalSettings
```

현재 셸이나 사용자 설정에 기존 `ANTHROPIC_*` credential/model override 또는
`CLAUDE_CODE_USE_*` provider selector가 있으면 Databricks 설정보다 우선할 수 있습니다.
설치기가 충돌을 보고하면 해당 변수를 제거한 새 셸에서 다시 실행하세요. 여러 provider를
완전히 격리해야 한다면
[기존 credential과 병행하는 방법](claude-code-databricks-reference.md#기존-anthropic-api-credential과-병행)을
따릅니다.

### 설치기가 수행하는 작업

1. `.env`에서 workspace, token, model 로드
2. 네이티브 Anthropic API와 모델 후보 smoke test
3. Token을 사용자 전용 파일에 저장하고 `apiKeyHelper` 생성
4. 선택한 settings 파일에 Databricks base URL과 모델 프리셋 병합
5. 현재 사용자의 `/model` 후보를 검증된 Databricks 모델로 정리
6. Databricks custom base URL에서 지원되지 않는 beta와 hosted `WebSearch` 비활성화
7. Claude Code를 실제 실행해 종단 간 검증

설치 결과에는 Databricks Anthropic base URL, `apiKeyHelper`, Opus/Sonnet/Haiku alias,
beta 차단, `WebSearch` deny, 검증된 모델 목록이 포함됩니다. 전체 파일 구조와 설정 이유는
[자동 설정 결과물](claude-code-databricks-reference.md#2-자동-설정-결과물)을
확인하세요.

설치기는 `ANTHROPIC_MODEL`을 고정하지 않고 `ANTHROPIC_DEFAULT_*_MODEL`만 설정합니다.
사용자 settings의 모델 목록은 현재 사용자의 실수 방지를 위한 설정이며 조직 정책이
아닙니다. 조직 전체 모델 제한과 `Default` 강제는 공식 문서에 따라 managed settings로
배포하세요.

## 3. 연결 확인

```bash
claude --model databricks-claude-opus-4-8 \
  -p "Reply with exactly: DIRECT OK" \
  --output-format json
```

정상 응답에서 `is_error`는 `false`이고 결과에는 `DIRECT OK`가 포함됩니다.

대화형 실행:

```bash
claude
```

실행 중 `/model`을 열면 설치기가 검증한 Databricks 모델을 선택할 수 있습니다.

## 4. 스크립트 없이 수동 설정

Credential helper 생성, settings 범위 선택, JSON 병합, 충돌 제거를 직접 수행하려면
[Claude Code와 Azure Databricks 수동 연결](claude-code-databricks-manual.md)을
따르세요. 자동 설치기가 무엇을 구성하는지 단계별로 확인할 수 있습니다.

### 현재 셸에서 한 번만 테스트

영구 설정 전에 현재 셸에서 연결만 확인하려면 다음 값을 직접 지정합니다.

macOS/Linux:

```bash
set -a
. ./.env
set +a

export ANTHROPIC_BASE_URL="${DATABRICKS_HOST%/}/serving-endpoints/anthropic"
export ANTHROPIC_AUTH_TOKEN="$DATABRICKS_TOKEN"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$DATABRICKS_SERVING_ENDPOINT"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

claude --model "$DATABRICKS_SERVING_ENDPOINT" \
  --disallowedTools WebSearch \
  -p "Reply with exactly: DIRECT OK"
```

테스트가 끝나면 현재 셸에서 token과 override를 제거합니다.

```bash
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN DATABRICKS_TOKEN
unset ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS
```

Windows를 포함한 영구 수동 설정은
[수동 연결 가이드](claude-code-databricks-manual.md)를 확인하세요.

## 5. 모델 전환

대화형 세션에서는 다음 명령을 사용합니다.

```text
/model
```

또는 시작할 때 모델 ID를 지정합니다.

```bash
claude --model databricks-claude-sonnet-5
```

모델 ID는 현재 workspace에서 실제 호출 가능한 값이어야 합니다.

## 6. 자주 발생하는 문제

| 증상 | 해결 |
| --- | --- |
| `401 Credential was not sent` | `apiKeyHelper` 경로와 token 파일 확인 |
| 다른 provider, host 또는 model이 사용됨 | 셸과 settings의 `CLAUDE_CODE_USE_*`, `ANTHROPIC_*` override를 제거하거나 격리된 config 사용 |
| beta 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` 확인 |
| `tool type 'web_search_*' is not supported` | `permissions.deny`에 bare `WebSearch` 추가 |
| `/model` 선택 후 모델을 찾지 못함 | Databricks의 실제 모델 ID와 리전 가용성 확인 |
| `403 ... rate limit of 0` | 모델·리전, cross-Geo, rate limit, custom endpoint의 `CAN QUERY`, Foundation Model UC의 `EXECUTE`, 계정 용량 확인 |
| HTTP 200이지만 `type: "message"`가 없음 | `/serving-endpoints/anthropic/v1/messages` 경로와 응답을 변형하는 gateway 확인 |

설정 복원과 credential 제거는
[Databricks 직접 연결 제거](claude-code-databricks-reference.md#10-databricks-직접-연결-제거)를
따르세요.

운영 인증, 모델 fallback, custom base URL 제한, gateway, LiteLLM 마이그레이션은
[Claude Code 상세 참고](claude-code-databricks-reference.md)를 확인하세요.

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude Code settings scopes](https://code.claude.com/docs/en/settings#configuration-scopes)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
