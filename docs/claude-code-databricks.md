# Claude Code에서 Azure Databricks의 Claude 모델 사용하기

Azure Databricks Model Serving은 현재 **네이티브 Anthropic Messages API**를 제공합니다.
따라서 Claude Code를 Databricks-hosted Claude에 연결할 때 로컬 LiteLLM 프록시는
필요하지 않습니다.

이 문서의 직접 연결은 Claude Code의 범용 `ANTHROPIC_BASE_URL`을 사용하는 custom
gateway 구성입니다. Claude Code의 내장 first-party provider 목록에 Databricks가
추가된 것은 아닙니다. Databricks가 coding-agent 통합에 권장하는 Unity AI Gateway 경로는
[§7](#7-두-ai-gateway-경로-구분)의 `ucode`를 사용합니다.

```text
Claude Code ──(Anthropic /v1/messages)──► Azure Databricks Model Serving
                                           /serving-endpoints/anthropic
```

> 최종 검증: 2026-07-11, Claude Code 2.1.207, `databricks-claude-opus-4-8`,
> 단일/다중 턴, high effort, `stop_sequences`, 도구 호출.

---

## 1. 왜 LiteLLM이 더 이상 필요하지 않은가

기존 구성은 모델별 `/serving-endpoints/<model>/invocations`를 호출했습니다. 이 경로는
OpenAI Chat Completions 형식으로 응답하므로 Anthropic 형식을 요구하는 Claude Code와
직접 호환되지 않았고, LiteLLM이 중간에서 프로토콜을 변환해야 했습니다.

현재 Azure Databricks는 다음 Anthropic 호환 경로를 제공합니다.

```text
POST https://<workspace>/serving-endpoints/anthropic/v1/messages
```

요청과 응답이 모두 Anthropic Messages 형식이므로 Claude Code가 직접 연결됩니다.

| 방식 | 경로 | LiteLLM |
| --- | --- | --- |
| **이 가이드의 직접 연결** | `/serving-endpoints/anthropic/v1/messages` | 불필요 |
| Unity AI Gateway model service (Beta) | `/ai-gateway/anthropic/v1/messages` | 불필요 |
| 이전 모델별 호출 | `/serving-endpoints/<model>/invocations` | Claude Code에는 변환 필요 |

공식 문서:

- [Query with the Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Provider native APIs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/provider-native-apis)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Region별 Foundation Model 가용성](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/foundation-model-overview)

---

## 2. 사전 준비

1. **Azure Databricks 워크스페이스와 Claude 모델**
   - 예: `databricks-claude-opus-4-8`
   - [지원 모델](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)과
     [리전별 가용성](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/foundation-model-overview)을
     함께 확인합니다. Anthropic Messages 전용 문서의 모델 목록은 일반 model catalog보다
     늦게 갱신될 수 있으므로 실제 smoke test도 수행합니다.
2. **Databricks 인증 정보**
   - 개발/검증: 대상 모델을 호출할 수 있는 PAT(legacy). 가능하면 사용자 PAT보다
     서비스 주체 PAT를 사용합니다.
   - 운영: 서비스 주체의 OAuth M2M 권장
   - 일반 endpoint ACL의 `CAN QUERY`가 필요하며, Foundation Model Unity Catalog 권한
     기능을 활성화했다면 대상 `system.ai` 모델의 `EXECUTE`도 필요합니다.
3. **Claude Code**
   ```bash
   claude --version
   ```
   - 이 가이드의 기본 Sonnet 5 매핑까지 사용하려면 2.1.197 이상을 권장합니다.
   - 최소 버전은 Opus 4.8이 2.1.154, Fable 5가 2.1.170, Sonnet 5가 2.1.197입니다.
4. **로컬 도구**
   - macOS/Linux: `curl`과 Python 3
   - Windows: Windows PowerShell 5.1 이상 또는 PowerShell 7
5. **이 리포의 `.env`**
   ```bash
   cp .env.example .env
   ```

필수 값:

```dotenv
DATABRICKS_HOST=https://adb-xxxx.azuredatabricks.net
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=dapi...
```

선택 값:

```dotenv
DATABRICKS_FAST_ENDPOINT=databricks-claude-haiku-4-5
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5 databricks-claude-fable-5"
```

> **Fable 5 데이터 처리 주의:** 프롬프트와 응답은 trust and safety 목적으로 30일
> 보존되며 자동 안전 시스템으로 처리되고 일부 경우 사람 검토 대상이 될 수 있습니다.
> 안전 조사나 법적 요구가 있으면 30일을 넘어 보존될 수 있고, Anthropic은 이 보존
> 목적의 limited subprocessor입니다. 설치기 기본 후보에도 Fable 5가 포함되므로
> [공식 모델 정책](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models#claude-fable-5)을
> 먼저 확인하세요. 승인되지 않은 워크로드에서는 `DATABRICKS_MODELS`를 Fable을 제외한
> 모델 ID 목록으로 설정한 뒤 설치기를 실행하세요.

---

## 3. 빠른 설정

### macOS / Linux

```bash
scripts/setup_claude_code_databricks.sh
```

### Windows PowerShell

```powershell
.\scripts\setup_claude_code_databricks.ps1
```

실행 정책에 막히면:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_claude_code_databricks.ps1
```

환경변수로 자격증명을 전달할 수도 있습니다.

```bash
DATABRICKS_HOST=https://adb-xxxx.azuredatabricks.net \
DATABRICKS_TOKEN=dapi... \
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8 \
scripts/setup_claude_code_databricks.sh
```

스크립트가 수행하는 작업:

1. `.env` 또는 환경변수에서 Databricks 설정 로드
2. Claude Code와 충돌하는 ambient credential 사전 점검
   (macOS/Linux에서는 `curl`과 Python도 확인)
3. 네이티브 `/serving-endpoints/anthropic/v1/messages`와 모델 fallback 검증
4. Databricks 토큰을 사용자 전용 파일에 저장
5. `apiKeyHelper`, 검증된 모델 프리셋, 미지원 beta 헤더 제거 설정
6. Databricks가 지원하지 않는 Anthropic hosted `WebSearch` 도구 비활성화
7. 이전 LiteLLM launchd/systemd/Scheduled Task가 있으면 비활성화
8. Claude Code를 실제로 실행해 종단 간 검증

설정 과정에서 Python 가상환경, LiteLLM, 로컬 포트, 백그라운드 서비스는 생성하지
않습니다.

### 스크립트 없이 수동 연결

설정 스크립트는 필수 런타임 구성요소가 아닙니다. 이미 workspace URL, 토큰, 사용할
모델 ID를 알고 있다면 현재 셸에서 다음 값만 설정해 Claude Code를 직접 실행할 수
있습니다.

#### macOS / Linux

```bash
export ANTHROPIC_BASE_URL="https://<workspace>.azuredatabricks.net/serving-endpoints/anthropic"
export ANTHROPIC_AUTH_TOKEN="<databricks-token>"
export ANTHROPIC_MODEL="databricks-claude-opus-4-8"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="databricks-claude-sonnet-5"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="databricks-claude-haiku-4-5"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

claude --disallowedTools WebSearch
```

#### Windows PowerShell

```powershell
$env:ANTHROPIC_BASE_URL = "https://<workspace>.azuredatabricks.net/serving-endpoints/anthropic"
$env:ANTHROPIC_AUTH_TOKEN = "<databricks-token>"
$env:ANTHROPIC_MODEL = "databricks-claude-opus-4-8"
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = $env:ANTHROPIC_MODEL
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "databricks-claude-sonnet-5"
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "databricks-claude-haiku-4-5"
$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"

claude --disallowedTools WebSearch
```

위 모델 ID는 해당 workspace에서 실제 호출 가능한 값으로 바꾸세요. 기본 모델만 사용할
때는 `ANTHROPIC_MODEL`만으로 대화를 시작할 수 있지만, 프리셋 매핑을 생략하면
`/model haiku` 같은 별칭이 Anthropic 기본 ID로 해석될 수 있습니다. Claude Code 2.1.207
검증에서는 `claude-haiku-4-5-20251001`로 요청해 Databricks에서 모델을 찾지 못했습니다.

`WebSearch` deny를 생략해도 일반 코딩 작업은 시작할 수 있지만, 모델이 `WebSearch`를
호출하면 Claude Code가 `source=web_search_tool` 요청을 Databricks로 보내고 HTTP 400
`The provided request is not valid`로 실패했습니다. 위 `--disallowedTools` 값은 해당
실행에만 적용됩니다.

반복 사용하려면 [§4](#4-생성되는-설정)의 설정을 `~/.claude/settings.json`에 병합하고, PAT를 평문으로
저장하는 대신 `apiKeyHelper`를 구성하세요. 기존 `permissions.deny` 항목을 보존하면서
`WebSearch`를 추가해야 합니다. 수동 검증을 마치면 현재 셸의 토큰도
`unset ANTHROPIC_AUTH_TOKEN` 또는 `Remove-Item Env:ANTHROPIC_AUTH_TOKEN`으로 제거합니다.

---

## 4. 생성되는 설정

| 위치 | 역할 |
| --- | --- |
| `~/.claude/settings.json` | Databricks Anthropic URL, 모델 매핑, `apiKeyHelper` |
| `~/.claude-databricks/.env` | Databricks 토큰. macOS/Linux는 0600 |
| `~/.claude-databricks/get-token.sh` | macOS/Linux용 Claude Code credential helper |
| `~/.claude-databricks/get-token.ps1` | Windows용 Claude Code credential helper |
| `~/.claude/settings.json.bak.<timestamp>` | 기존 Claude 설정 백업 |

개념적으로 다음 설정이 병합됩니다.

```json
{
  "apiKeyHelper": "/Users/me/.claude-databricks/get-token.sh",
  "permissions": {
    "deny": ["WebSearch"]
  },
  "env": {
    "ANTHROPIC_BASE_URL": "https://adb-xxxx.azuredatabricks.net/serving-endpoints/anthropic",
    "ANTHROPIC_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "900000"
  }
}
```

Windows의 `apiKeyHelper`는 `powershell.exe ... get-token.ps1` 명령으로 저장됩니다.
Fable endpoint 검증까지 성공하면 `ANTHROPIC_DEFAULT_FABLE_MODEL`도 추가됩니다.

### `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`이 필요한 이유

Claude Code는 기본적으로 일부 Anthropic beta 헤더를 보낼 수 있습니다. Databricks
네이티브 Anthropic API는 지원하지 않는 beta 헤더나 필드를 거부할 수 있습니다. 이
리포의 검증에서는 다음과 같은 응답을 관찰했습니다.

```text
400 {"message":"invalid beta flag"}
```

설치기는 이 환경변수를 자동 설정합니다. 공식
[Claude Code 환경 변수 문서](https://code.claude.com/docs/en/env-vars)는 이 값을 `1`로
설정하면 Anthropic 전용 beta 요청 헤더와 beta 도구 스키마 필드를 제거한다고 설명합니다.

### `WebSearch`를 비활성화하는 이유

일반 Claude Code 도구 호출은 네이티브 API에서 동작하지만, Anthropic의 hosted
`WebSearch`는 현재 Databricks 네이티브 경로에서 지원이 문서화돼 있지 않습니다. 이
리포는 `web_search_20250305` 호출이 HTTP 400으로 거부되는 것을 확인했으며, Claude
Code 버전에 따라 hosted tool 버전 문자열은 바뀔 수 있습니다.
설치기는 기존 `permissions.deny` 규칙을 보존하면서 bare `WebSearch` 규칙을 추가해 이 도구가
모델에 노출되지 않도록 합니다. 웹 검색이 필요하면 MCP 검색 서버를 등록하거나 Unity AI
Gateway의 `ucode` 구성을 사용하세요.

### 토큰을 `settings.json`에 넣지 않는 이유

`ANTHROPIC_AUTH_TOKEN`에 PAT를 직접 저장하면 Claude 설정 파일에 비밀이 평문으로
남습니다. 설치기는 `apiKeyHelper`가 권한이 제한된 별도 파일에서 토큰을 읽도록
구성합니다.

운영 환경에서는 장기 PAT보다 서비스 주체 OAuth M2M을 권장합니다. 이 리포의 자동
설정기는 PAT helper만 생성하며 M2M 토큰 갱신 helper는 구현하지 않습니다. 조직 단위
OAuth 로그인이 필요하면 Unity AI Gateway의 `ucode`를 사용하거나, Databricks CLI/SDK가
발급한 단기 토큰을 반환하는 별도 `apiKeyHelper`를 운영해야 합니다.

운영용 OAuth M2M helper 예시입니다. 서비스 주체 M2M 프로필을 `.databrickscfg`에 한 번
구성한 뒤, 단기 access token만 출력하도록 `get-token.sh`를 교체하고 `apiKeyHelper`로
지정합니다. M2M은 대화형 브라우저 로그인(`databricks auth login`, U2M)이 아니라
`.databrickscfg` 프로필로 설정합니다.

```bash
# 1) ~/.databrickscfg 에 서비스 주체 M2M 프로필을 추가 (client_id/secret 필요)
cat >> ~/.databrickscfg <<'CFG'
[databricks-sp]
host          = https://<workspace>.azuredatabricks.net
client_id     = <SERVICE_PRINCIPAL_CLIENT_ID>
client_secret = <SERVICE_PRINCIPAL_OAUTH_SECRET>
CFG

# 2) ~/.claude-databricks/get-token.sh 를 아래 내용으로 교체
#    databricks auth token 은 {"access_token","token_type":"Bearer","expiry"} 를 반환
cat > ~/.claude-databricks/get-token.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
databricks auth token -p databricks-sp \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])'
SH
chmod 700 ~/.claude-databricks/get-token.sh
```

이 access token은 약 1시간 수명이며, 설정된 `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`(이
리포 기본값 15분)마다 Claude Code가 만료 전에 helper를 다시 호출해 재발급합니다.
`Bearer` 토큰이므로 Databricks 네이티브 Anthropic 엔드포인트 인증과 그대로 맞습니다.
자동 설정기는 이 M2M helper를 생성하지 않으므로 운영 환경에서만 위 helper로 교체하세요.
서비스 주체 OAuth secret 발급은
[OAuth M2M 설정](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m),
CLI 프로필 구성은
[Databricks CLI 인증](https://learn.microsoft.com/azure/databricks/dev-tools/cli/authentication)을
참고하세요.

### Custom base URL에서 달라지는 Claude Code 기능

Claude Code는 `ANTHROPIC_BASE_URL`이 `api.anthropic.com`이 아닌 호스트를 가리키면 MCP
tool search를 기본 비활성화하고 Remote Control도 비활성화합니다. Databricks 경로가
`tool_reference` block을 전달한다는 보장이 없으므로 `ENABLE_TOOL_SEARCH=true`를
임의로 켜지 마세요. 일반 MCP 서버와 로컬 도구 호출은 이 제한과 별개입니다.

`--settings <custom.json>`은 기존 settings와 병합되며 `apiKeyHelper`도 사용할 수
있습니다. Claude Code 2.1.206에서 custom settings 파일과 helper 조합을 직접
검증했습니다. 완전히 격리된 검증이 필요할 때만 `CLAUDE_CONFIG_DIR`을 별도 디렉터리로
지정하세요.

---

## 5. 모델 전환

설치기는 다음 환경변수로 Claude Code의 모델 프리셋을 Databricks 모델에 연결합니다.

- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_DEFAULT_FABLE_MODEL` (해당 endpoint가 실제 검증된 경우에만)

`ANTHROPIC_DEFAULT_HAIKU_MODEL`은 `/model haiku`와 세션 제목 생성 등 Claude Code의
경량 백그라운드 작업에 사용됩니다. Claude Code 2.1.207에서 auto 권한 모드의 LLM
분류기는 이 값이 아니라 현재 메인 모델을 사용했습니다. `ANTHROPIC_SMALL_FAST_MODEL`
없이도 제목 생성은 Haiku, auto-mode 분류는 메인 Opus로 정상 동작했습니다.

이전 `ANTHROPIC_SMALL_FAST_MODEL`은 deprecated이며 별도로 설정할 필요가 없습니다.
명시적 `DATABRICKS_FAST_ENDPOINT`가 없으면 설치기가 기존 값을 먼저 검증해
`ANTHROPIC_DEFAULT_HAIKU_MODEL`로 이동한 뒤 deprecated key를 제거합니다.

Claude Code에서 실행 중 다음 명령으로 전환합니다.

```text
/model
```

또는:

```bash
claude --model databricks-claude-sonnet-5
```

네이티브 Anthropic 엔드포인트는 요청의 `model` 값을 보고 해당 Databricks 모델로
라우팅하므로 LiteLLM의 `model_list` 등록이 필요하지 않습니다.

설치기는 각 모델을 먼저 호출해 검증합니다. Opus/Sonnet 프리셋은 각 family에서 처음
검증된 후보를 사용하고, 검증된 같은 family 후보가 없으면 검증된 기본 모델로
fallback합니다. `DATABRICKS_FAST_ENDPOINT` 검증이 실패하면 Haiku 프리셋도 같은 기본
모델을 사용하며, 설치기가 `DATABRICKS_MODELS`의 다른 Haiku 후보를 자동 선택하지는
않습니다. 이 fallback은 `/model`이 지원되지 않는 Anthropic 기본 ID로 빠지지 않게
합니다.
Fable은 다른 family로 조용히 대체하지 않고 `databricks-claude-fable-5`가 실제
검증됐을 때만 매핑합니다. 해당 모델이 없는 workspace에서 `/model fable`을 선택하면
요청이 실패할 수 있습니다.

Databricks의 현재 Sonnet 5 문서는 `temperature`, `top_p`, `top_k`를 지원하지 않는다고
명시합니다. 이 리포의 Claude Code 설정과 Python 샘플은 해당 sampling parameter를
추가하지 않습니다.

---

## 6. 수동 API 확인

```bash
set -a
. ./.env
set +a

printf 'header = "Authorization: Bearer %s"\n' "$DATABRICKS_TOKEN" |
curl --config - -sS "$DATABRICKS_HOST/serving-endpoints/anthropic/v1/messages" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "databricks-claude-opus-4-8",
    "max_tokens": 32,
    "messages": [
      {"role": "user", "content": "Reply with exactly: DIRECT OK"}
    ]
  }'
```

정상 응답의 핵심 필드:

```json
{
  "type": "message",
  "content": [
    {"type": "text", "text": "DIRECT OK"}
  ]
}
```

Claude Code 종단 간:

```bash
claude --model databricks-claude-opus-4-8 \
  -p "Reply with exactly: CLAUDE OK" \
  --output-format json
```

---

## 7. 두 AI Gateway 경로 구분

Databricks 문서에는 이름이 비슷한 두 관리 계층이 있습니다. 둘 다 로컬에 설치하는
프록시는 아닙니다.

| 구분 | 적용 위치 | 이 가이드와의 관계 |
| --- | --- | --- |
| **AI Gateway for serving endpoints** (이전 세대) | Serving endpoint 상세 화면 | 이 가이드의 `/serving-endpoints/anthropic` 호출에 usage tracking, rate limit, payload logging, guardrail을 endpoint 단위로 설정 |
| **Unity AI Gateway** (Beta) | 왼쪽 **AI Gateway** 메뉴의 Unity Catalog model service | `/ai-gateway/anthropic` 경로, service policy, budget, 통합 usage dashboard, traffic splitting/fallback |

이전 세대 endpoint gateway에서는 pay-per-token Foundation Model endpoint에 fallback과
traffic splitting을 적용할 수 없습니다. 새 Unity AI Gateway model service의 routing
기능과 혼동하지 마세요.

새 Unity AI Gateway에는 다음 조건이 필요합니다.

- Account Console → **Previews**에서 Unity AI Gateway 활성화
- Unity Catalog 활성화
- 지원 리전

Beta가 꺼져 있어도 본 문서의 `/serving-endpoints/anthropic` 직접 연결은 사용할 수
있습니다. Preview 상태는 Account Console과 workspace의 **AI Gateway** 메뉴에서
확인하세요. 비공개 또는 내부 API 응답만으로 가용성을 판정하지 않습니다.

### Unity AI Gateway를 사용하는 경우

Databricks가 권장하는 `ucode`가 사용자 OAuth 로그인, 모델 검색, Claude 설정을
자동화합니다. `ucode`는 Python 3.12 이상과 `uv`가 필요합니다.

```bash
uv tool install git+https://github.com/databricks/ucode
ucode claude
```

이때 Claude Code의 base URL은 다음 관리형 경로를 사용합니다.

```text
https://<workspace>/ai-gateway/anthropic
```

`ucode` 경로의 model service 사용량은 `system.ai_gateway.usage`와 빌트인 AI Gateway
dashboard에서 확인합니다. 이 Beta system table은 현재 account admin만 조회할 수
있습니다. 반면 이전 세대 endpoint usage는 `system.serving.endpoint_usage`와
`system.serving.served_entities`를 사용합니다.

공식 문서:

- [AI governance with Unity AI Gateway](https://learn.microsoft.com/azure/databricks/ai-gateway/)
- [Integrate with coding agents](https://learn.microsoft.com/azure/databricks/ai-gateway/coding-agent-integration-model-services)
- [AI Gateway for serving endpoints](https://learn.microsoft.com/azure/databricks/ai-gateway/overview-serving-endpoints)
- [`databricks/ucode`](https://github.com/databricks/ucode)

---

## 8. 기존 LiteLLM 설치에서 마이그레이션

최신 설정 스크립트를 다시 실행하면:

- Claude Code base URL을 Databricks 네이티브 Anthropic API로 변경
- `ANTHROPIC_AUTH_TOKEN`의 기존 로컬 프록시 키 제거
- 기존 `ANTHROPIC_SMALL_FAST_MODEL` 값을 Haiku 프리셋으로 이관한 뒤 deprecated key 제거
- launchd/systemd/Scheduled Task로 등록된 이전 프록시 비활성화
- 기존 LiteLLM 파일은 삭제하지 않고 비활성 상태로 보존

새 연결을 확인한 뒤 다음 레거시 파일을 정리할 수 있습니다.

### macOS / Linux

```bash
rm -rf ~/.claude-databricks/.venv
rm -f ~/.claude-databricks/config.yaml
rm -f ~/.claude-databricks/custom_handlers.py
rm -f ~/.claude-databricks/start-proxy.sh
rm -f ~/.claude-databricks/proxy.log
```

다음 파일은 직접 연결에서 계속 사용하므로 삭제하지 않습니다.

```text
~/.claude-databricks/.env
~/.claude-databricks/get-token.sh
```

### Windows

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-databricks\.venv" `
  -ErrorAction SilentlyContinue
Remove-Item -Force `
  "$env:USERPROFILE\.claude-databricks\config.yaml", `
  "$env:USERPROFILE\.claude-databricks\custom_handlers.py", `
  "$env:USERPROFILE\.claude-databricks\start-proxy.ps1", `
  "$env:USERPROFILE\.claude-databricks\proxy.log" `
  -ErrorAction SilentlyContinue
```

`.env`와 `get-token.ps1`은 유지합니다.

---

## 9. 문제 해결

| 증상 | 원인 / 해결 |
| --- | --- |
| 지원하지 않는 `anthropic-beta`/필드 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` 확인 후 Claude Code 재시작 |
| `401 Credential was not sent` | `apiKeyHelper` 경로와 `~/.claude-databricks/.env` 권한/토큰 확인 |
| 설정은 맞지만 다른 키로 인증됨 | 셸/프로필의 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`를 unset한 뒤 설치기와 Claude Code 재실행 |
| `403 ... rate limit of 0` | 일반 429 초과와 다름. 모델/리전, cross-Geo, endpoint·사용자 rate limit, 권한, 계정 용량을 README 순서대로 확인 |
| `/ai-gateway/...` 호출 실패 | Account Console의 Unity AI Gateway Preview, Unity Catalog, 지원 리전, model service 권한 확인. 직접 연결은 `/serving-endpoints/anthropic` 사용 |
| `/model`의 모델이 실패 | 해당 모델의 현재 리전 가용성과 endpoint ID 확인 |
| `/model fable`이 실패 | `databricks-claude-fable-5`가 현재 workspace에서 검증되지 않아 family mapping을 만들지 않은 상태일 수 있음 |
| Python Agent Framework 두 번째 턴에서 `messages.N.name` 오류 | `src/agent_sample.py`의 최소 호환 훅이 최신인지 확인 |
| `tool type 'web_search_*' is not supported` | `permissions.deny`에 bare `WebSearch` 추가 또는 MCP 검색 서버 사용 |
| Remote Control 또는 MCP tool search가 보이지 않음 | custom `ANTHROPIC_BASE_URL`의 기본 제한. 일반 MCP 서버는 별개이며 tool search를 강제로 켜기 전 gateway의 `tool_reference` 지원 확인 |
| 이전 포트 4000 프로세스가 남음 | 더 이상 사용되지 않는 LiteLLM 프로세스. PID를 확인한 뒤 해당 PID만 종료 |

macOS에서 과거 프록시 PID 확인:

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN
```

---

## 10. LiteLLM이 여전히 필요한 경우

다음과 같은 예외적인 경우에만 별도 프록시를 고려합니다.

- 네이티브 `/serving-endpoints/anthropic` API를 제공하지 않는 오래된 환경
- Databricks 외 여러 공급자를 로컬에서 임의 라우팅해야 하는 경우
- 조직 고유의 요청/응답 변환 로직이 필요한 경우

이 리포가 대상으로 하는 현재 Azure Databricks-hosted Claude + Claude Code 구성에는
LiteLLM이 필요하지 않습니다.

Claude Code 모델 환경변수의 최신 의미는
[Model configuration](https://code.claude.com/docs/en/model-config#environment-variables)을
참고하세요.

추가 참고:

- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Foundation model Unity Catalog permissions](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/model-uc-permissions)
- [Model usage for Unity AI Gateway services](https://learn.microsoft.com/azure/databricks/ai-gateway/usage-tracking)
