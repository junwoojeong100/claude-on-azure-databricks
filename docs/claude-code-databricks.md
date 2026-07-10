# Claude Code에서 Azure Databricks의 Claude 모델 사용하기

Azure Databricks Model Serving은 현재 **네이티브 Anthropic Messages API**를 제공합니다.
따라서 Claude Code를 Databricks-hosted Claude에 연결할 때 로컬 LiteLLM 프록시는
필요하지 않습니다.

```text
Claude Code ──(Anthropic /v1/messages)──► Azure Databricks Model Serving
                                           /serving-endpoints/anthropic
```

> 검증 기준: Claude Code 2.1.206, `databricks-claude-opus-4-8`,
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
| **현재 권장** | `/serving-endpoints/anthropic/v1/messages` | 불필요 |
| Unity AI Gateway (Beta, v2 API) | `/ai-gateway/anthropic/v1/messages` | 불필요 |
| 이전 모델별 호출 | `/serving-endpoints/<model>/invocations` | Claude Code에는 변환 필요 |

공식 문서:

- [Query with the Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Provider native APIs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/provider-native-apis)

---

## 2. 사전 준비

1. **Azure Databricks 워크스페이스와 Claude 모델**
   - 예: `databricks-claude-opus-4-8`
   - 모델/리전 가용성은
     [지원 모델 문서](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)를 확인합니다.
2. **Databricks 인증 정보**
   - 개발/검증: 대상 모델을 호출할 수 있는 PAT
   - 운영: 서비스 주체의 OAuth M2M 권장
3. **Claude Code**
   ```bash
   claude --version
   ```
4. **이 리포의 `.env`**
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
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5"
```

---

## 3. 빠른 설정

### macOS / Linux

```bash
scripts/setup_claude_code_databricks.sh
```

### Windows PowerShell

```powershell
scripts\setup_claude_code_databricks.ps1
```

실행 정책에 막히면:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup_claude_code_databricks.ps1
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
2. 네이티브 `/serving-endpoints/anthropic/v1/messages` 호출 검증
3. Databricks 토큰을 사용자 전용 파일에 저장
4. Claude Code `apiKeyHelper`와 모델 환경변수 설정
5. Databricks가 지원하지 않는 Anthropic hosted `WebSearch` 도구 비활성화
6. 이전 LiteLLM launchd/systemd/Scheduled Task가 있으면 비활성화
7. Claude Code를 실제로 실행해 종단 간 검증

설정 과정에서 Python 가상환경, LiteLLM, 로컬 포트, 백그라운드 서비스는 생성하지
않습니다.

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
    "ANTHROPIC_SMALL_FAST_MODEL": "databricks-claude-haiku-4-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "900000"
  }
}
```

Windows의 `apiKeyHelper`는 `powershell.exe ... get-token.ps1` 명령으로 저장됩니다.

### `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`이 필요한 이유

Claude Code는 기본적으로 일부 Anthropic beta 헤더를 보낼 수 있습니다. Databricks
네이티브 Anthropic API는 지원하지 않는 beta 헤더를 다음과 같이 거부합니다.

```text
400 {"message":"invalid beta flag"}
```

설치기는 이 환경변수를 자동 설정합니다.

### `WebSearch`를 비활성화하는 이유

일반 Claude Code 도구 호출은 네이티브 API에서 동작하지만, Anthropic의 hosted
`web_search_20250305` 도구 형식은 Databricks 모델이 지원하지 않아 HTTP 400을 반환합니다.
설치기는 기존 `permissions.deny` 규칙을 보존하면서 bare `WebSearch` 규칙을 추가해 이 도구가
모델에 노출되지 않도록 합니다. 웹 검색이 필요하면 MCP 검색 서버를 등록하거나 Unity AI
Gateway의 `ucode` 구성을 사용하세요.

### 토큰을 `settings.json`에 넣지 않는 이유

`ANTHROPIC_AUTH_TOKEN`에 PAT를 직접 저장하면 Claude 설정 파일에 비밀이 평문으로
남습니다. 설치기는 `apiKeyHelper`가 권한이 제한된 별도 파일에서 토큰을 읽도록
구성합니다.

운영 환경에서는 장기 PAT보다 OAuth M2M 또는 Unity AI Gateway의 `ucode` 인증을
권장합니다.

> 검증한 Claude Code 2.1.206에서는 `apiKeyHelper`가 일반
> `CLAUDE_CONFIG_DIR/settings.json`에서 정상 동작했지만, `--settings <custom.json>`만으로
> 실행하면 인증 정보가 전달되지 않았습니다. Helper 인증을 사용할 때는 기본 설정 위치 또는
> `CLAUDE_CONFIG_DIR`을 사용하세요.

---

## 5. 모델 전환

설치기는 다음 환경변수로 Claude Code의 모델 프리셋을 Databricks 모델에 연결합니다.

- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_SMALL_FAST_MODEL`

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

설치기는 각 모델을 먼저 호출해 검증합니다. 특정 Opus/Sonnet/Haiku 모델이 현재 리전에서
실패하면 해당 family 프리셋은 검증된 기본 모델로, Haiku 프리셋은 검증된 small/fast 모델로
fallback하여 `/model`이 지원되지 않는 Anthropic 기본 ID로 빠지지 않게 합니다.

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

## 7. Unity AI Gateway는 무엇인가

Unity AI Gateway는 Unity Catalog 기반의 Databricks 관리형 AI 거버넌스 계층입니다.
로컬에 설치하는 프록시가 아닙니다.

- 모델·Agent·MCP 서비스를 Unity Catalog 권한으로 제어
- 사용자/그룹별 rate limit과 예산
- 트래픽 분할과 fallback
- 요청/응답 guardrail
- 토큰·비용·지연시간 대시보드
- Inference Tables를 통한 요청/응답 감사

새 Unity AI Gateway 환경은 현재 Beta이며 v2 API를 사용합니다. 다음 조건이 필요합니다.

- Account Previews에서 Unity AI Gateway 활성화
- Unity Catalog 활성화
- 지원 리전

가용성 확인:

```bash
printf 'header = "Authorization: Bearer %s"\n' "$DATABRICKS_TOKEN" |
curl --config - -sS \
  "$DATABRICKS_HOST/api/ai-gateway/v2/endpoints?page_size=1"
```

`404 FEATURE_DISABLED`이면 Unity AI Gateway Beta가 활성화되지 않은 것입니다. 이 경우에도 본 문서의
`/serving-endpoints/anthropic` 직접 경로는 사용할 수 있습니다.

### Unity AI Gateway Beta가 활성화된 경우

Databricks의 `ucode`가 OAuth 로그인, 모델 검색, Claude 설정을 자동화합니다.

```bash
uv tool install git+https://github.com/databricks/ucode
ucode claude
```

이때 Claude Code의 base URL은 다음 관리형 경로를 사용합니다.

```text
https://<workspace>/ai-gateway/anthropic
```

공식 문서:

- [AI governance with Unity AI Gateway](https://learn.microsoft.com/azure/databricks/ai-gateway/)
- [Integrate with coding agents](https://learn.microsoft.com/azure/databricks/ai-gateway/coding-agent-integration-model-services)
- [`databricks/ucode`](https://github.com/databricks/ucode)

---

## 8. 기존 LiteLLM 설치에서 마이그레이션

최신 설정 스크립트를 다시 실행하면:

- Claude Code base URL을 Databricks 네이티브 Anthropic API로 변경
- `ANTHROPIC_AUTH_TOKEN`의 기존 로컬 프록시 키 제거
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
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-databricks\.venv"
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
| `400 invalid beta flag` | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` 확인 후 Claude Code 재시작 |
| `401 Credential was not sent` | `apiKeyHelper` 경로와 `~/.claude-databricks/.env` 권한/토큰 확인 |
| 설정은 맞지만 다른 키로 인증됨 | 셸/프로필의 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`를 unset한 뒤 설치기와 Claude Code 재실행 |
| `403 ... rate limit of 0` | Anthropic 모델 용량 또는 계정 활성화 문제. README 문제 해결 절 참고 |
| `/ai-gateway/...`가 `404 FEATURE_DISABLED` | Unity AI Gateway (Beta, v2 API) 미활성. `/serving-endpoints/anthropic` 직접 경로 사용 |
| `/model`의 모델이 실패 | 해당 모델의 현재 리전 가용성과 endpoint ID 확인 |
| Python Agent Framework 두 번째 턴에서 `messages.N.name` 오류 | `src/agent_sample.py`의 최소 호환 훅이 최신인지 확인 |
| `tool type 'web_search_20250305' is not supported` | `permissions.deny`에 bare `WebSearch` 추가 또는 MCP 검색 서버 사용 |
| `--settings custom.json`에서 401 | `apiKeyHelper`가 로드되는 기본 설정 또는 `CLAUDE_CONFIG_DIR/settings.json` 사용 |
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
