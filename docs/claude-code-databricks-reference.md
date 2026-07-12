# Claude Code × Azure Databricks 상세 참고

이 문서는 [직접 연결 가이드](claude-code-databricks.md)의 운영·인증·문제 해결
세부사항을 모은 참고 문서입니다. 처음 설정하는 사용자는 직접 연결 가이드부터
따르세요.

## 1. 직접 연결 구조

```text
Claude Code ──(Anthropic /v1/messages)──► Azure Databricks
                                           /serving-endpoints/anthropic
```

`ANTHROPIC_BASE_URL`에는 `/v1/messages`를 제외한 다음 URL을 설정합니다.

```text
https://<workspace-host>/serving-endpoints/anthropic
```

Claude Code가 마지막 `/v1/messages`를 붙입니다.

| 방식 | 경로 | LiteLLM |
| --- | --- | --- |
| 이 리포의 직접 연결 | `/serving-endpoints/anthropic/v1/messages` | 불필요 |
| Unity AI Gateway model service | `/ai-gateway/anthropic/v1/messages` | 불필요 |
| 이전 모델별 invocations | `/serving-endpoints/<model>/invocations` | Claude Code에는 형식 변환 필요 |

## 2. 자동 설정 결과물

| 위치 | 역할 |
| --- | --- |
| 선택한 settings 파일(기본 `~/.claude/settings.json`) | Databricks Anthropic URL, 모델 프리셋, `apiKeyHelper` |
| `~/.claude-databricks/.env` | Credential source; helper가 `DATABRICKS_TOKEN`을 읽음 |
| `~/.claude-databricks/get-token.sh` | macOS/Linux credential helper |
| `~/.claude-databricks/get-token.ps1` | Windows credential helper |
| `<settings-file>.bak.<timestamp>` | 기존 Claude 설정 백업 |

macOS/Linux에서는 state directory가 `0700`, token 파일이 `0600`, helper가 `0700`으로
설정됩니다. Windows에서는 현재 사용자만 수정할 수 있도록 ACL을 제한합니다.

설치기는 기존 JSON의 다른 설정을 보존합니다. 다음 값은 Databricks 직접 연결과
충돌하므로 제거합니다.

- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_MODEL`
- `ANTHROPIC_SMALL_FAST_MODEL`
- 기존 `ANTHROPIC_DEFAULT_*_MODEL`

그 후 검증된 값으로 `ANTHROPIC_DEFAULT_*_MODEL`을 다시 구성합니다.
`availableModels`와 `enforceAvailableModels`도 설정해 `/model`과 시작 모델이 검증된
Databricks 모델 밖으로 나가지 않게 합니다. Fable은 명시적으로 opt-in하고 endpoint
검증에 성공한 경우에만 allowlist와 family mapping에 추가됩니다.
이 리포가 쓰는 사용자 `settings.json`은 현재 사용자 범위의 보호 장치입니다. 조직
전체 강제 정책은 같은 두 키를 최고 우선순위 managed/policy settings에 배포해야 하며,
managed 설정이 있으면 사용자 목록보다 우선합니다.
`enforceAvailableModels`가 `/model`의 `Default` 옵션까지 잠그는 동작은 Claude Code
2.1.175 이상에서 지원됩니다.

기본 경로는 모든 프로젝트에 적용됩니다. 기존 Anthropic 연결을 프로젝트별로 유지하려면
`CLAUDE_SETTINGS=.claude/settings.local.json` 또는 PowerShell의 `-ClaudeSettings`로
리포 로컬 파일을 선택합니다. 공유용 `.claude/settings.json`과 달리
`settings.local.json`은 이 리포의 `.gitignore`에 포함됩니다.

### 백업에서 복원

설치기는 기존 settings 파일이 있을 때마다 같은 디렉터리에 timestamp 백업을 만듭니다.
설치 직전 백업을 선택하고, 이후 추가한 설정이 있다면 복원 전에 비교하세요.

macOS/Linux 기본 경로:

```bash
ls -1t "$HOME"/.claude/settings.json.bak.*
cp "$HOME/.claude/settings.json.bak.<timestamp>" "$HOME/.claude/settings.json"
```

Windows 기본 경로:

```powershell
Get-ChildItem "$HOME\.claude\settings.json.bak.*" |
    Sort-Object LastWriteTime -Descending
Copy-Item "$HOME\.claude\settings.json.bak.<timestamp>" `
    "$HOME\.claude\settings.json" -Force
```

사용자 지정 settings 파일은 해당 파일 옆의 `.bak.<timestamp>`를 복원합니다.

## 3. 필수 설정의 이유

### `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`

Claude Code는 Anthropic beta 헤더나 beta 도구 필드를 보낼 수 있습니다. Databricks
네이티브 API가 지원하지 않는 beta를 받으면 400을 반환할 수 있으므로 이 값을 `1`로
설정합니다.

### `permissions.deny: ["WebSearch"]`

일반적인 Claude Code 도구 호출은 동작하지만 Anthropic hosted `WebSearch`는 현재
Databricks 네이티브 경로에서 지원이 문서화돼 있지 않습니다. 이 리포의 검증에서도
`web_search_20250305` 요청이 HTTP 400으로 거부됐습니다.

기존 deny 규칙을 지우지 말고 bare `WebSearch`만 추가합니다. 웹 검색이 필요하면
별도의 MCP 검색 서버 또는 Unity AI Gateway의 coding-agent 통합을 검토하세요.

### `apiKeyHelper`

PAT를 `settings.json`의 `ANTHROPIC_AUTH_TOKEN`에 직접 저장하면 설정 파일에 비밀이
평문으로 남습니다. Helper는 보호된 별도 파일 또는 단기 OAuth token 발급 명령에서
credential을 읽습니다.

### `ANTHROPIC_MODEL`을 설정하지 않는 이유

Opus/Sonnet/Haiku 프리셋과 같은 모델을 `ANTHROPIC_MODEL`에도 설정하면 `/model` 목록에
중복 선택지가 생길 수 있습니다. 기본 선택과 family alias는
`ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
`ANTHROPIC_DEFAULT_HAIKU_MODEL`로 제어합니다.

## 4. 모델 검증과 fallback

자동 설치기는 기본 모델, Haiku 후보, `DATABRICKS_MODELS` 후보를 네이티브 Anthropic
API로 먼저 호출합니다.

1. 기본 모델 검증 실패: 설정 중단
2. Haiku 검증 실패: 기본 모델을 Haiku 프리셋에도 사용
3. Opus/Sonnet 후보 실패: 검증된 같은 family를 우선하고, 없으면 기본 모델 사용
4. Fable 검증 실패: 다른 family로 대체하지 않고 Fable mapping을 만들지 않음

Fable 5는 다음 정책 때문에 명시적 검토가 필요합니다.

- 프롬프트와 응답 30일 보존
- 자동 safety system 처리
- 일부 경우 사람 검토
- 안전 조사 또는 법적 요구 시 30일 초과 보존 가능

정책을 승인한 환경에서만 Fable을 명시적으로 추가합니다.

```bash
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5 databricks-claude-fable-5" \
  scripts/setup_claude_code_databricks.sh
```

Databricks의 Sonnet 5는 `temperature`, `top_p`, `top_k`를 지원하지 않습니다. 이 리포의
설정과 테스트는 해당 sampling parameter를 추가하지 않습니다.

## 5. 운영용 OAuth M2M helper

자동 설치기는 로컬 실습용 PAT helper를 만듭니다. 운영에서는 Databricks OAuth
M2M 서비스 주체를 사용하고, `apiKeyHelper`가 workspace token endpoint에서 단기
access token을 발급받도록 구성할 수 있습니다.

`~/.claude-databricks/m2m.env`를 만들고 `0600`으로 제한합니다.

```dotenv
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_CLIENT_ID=<service-principal-client-id>
DATABRICKS_CLIENT_SECRET=<service-principal-oauth-secret>
```

```bash
chmod 600 ~/.claude-databricks/m2m.env
```

`~/.claude-databricks/get-token.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TOKEN_FILE="$(cd "$(dirname "$0")" && pwd)/m2m.env"
python3 - "$TOKEN_FILE" <<'PY'
import base64
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

values = {}
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    values[key.strip()] = value.strip().strip('"').strip("'")

host = values["DATABRICKS_HOST"].rstrip("/")
client_id = values["DATABRICKS_CLIENT_ID"]
client_secret = values["DATABRICKS_CLIENT_SECRET"]
basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
body = urllib.parse.urlencode(
    {"grant_type": "client_credentials", "scope": "all-apis"}
).encode()
request = urllib.request.Request(
    f"{host}/oidc/v1/token",
    data=body,
    headers={
        "Authorization": f"Basic {basic}",
        "Content-Type": "application/x-www-form-urlencoded",
    },
)
with urllib.request.urlopen(request, timeout=30) as response:
    print(json.load(response)["access_token"], end="")
PY
```

```bash
chmod 700 ~/.claude-databricks/get-token.sh
```

Access token은 1시간 동안 유효합니다. 이 리포의
`CLAUDE_CODE_API_KEY_HELPER_TTL_MS=900000`은 15분마다 helper 결과를 갱신할 수 있게
합니다.

Databricks CLI의 일반 명령은 `client_id`/`client_secret` M2M profile을 지원합니다.
이 예시는 helper가 CLI 로그인 캐시에 의존하지 않도록 `/oidc/v1/token`을 직접
호출합니다. `databricks auth login`은 사용자 브라우저 로그인(U2M) 경로입니다.

## 6. 수동 API 검증

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
      \"max_tokens\": 32,
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: DIRECT OK\"}]
    }"
```

정상 응답:

```json
{
  "type": "message",
  "content": [
    {
      "type": "text",
      "text": "DIRECT OK"
    }
  ]
}
```

Anthropic Messages 전용 문서의 지원 모델 목록이 전체 model catalog보다 늦게 갱신될 수
있으므로, model catalog와 실제 smoke test를 함께 사용합니다.

## 7. Custom base URL에서 달라지는 기능

`ANTHROPIC_BASE_URL`이 Anthropic 기본 호스트가 아닌 custom gateway를 가리키면 Claude
Code는 일부 provider-specific 기능을 기본 비활성화할 수 있습니다.

- MCP tool search 기본 비활성화
- Remote Control 비활성화
- 일반 MCP 서버와 로컬 도구는 계속 사용 가능

Databricks 경로가 `tool_reference` block을 지원한다는 확인 없이
`ENABLE_TOOL_SEARCH=true`를 강제로 설정하지 마세요.

## 8. 두 AI Gateway 구분

Databricks 문서에는 이름이 비슷한 두 관리 계층이 있습니다. 둘 다 로컬 프록시는
아닙니다.

| 구분 | 경로/위치 | 역할 |
| --- | --- | --- |
| AI Gateway for serving endpoints | Serving endpoint 상세 | endpoint별 usage tracking, rate limit, payload logging, guardrail |
| Unity AI Gateway (Beta) | `/ai-gateway/anthropic` | Unity Catalog model/model provider service, budget, service policy, routing, 통합 관측 |

이 리포의 `/serving-endpoints/anthropic` 직접 연결에는 Unity AI Gateway Preview가
필수 조건이 아닙니다.

Unity AI Gateway를 사용하는 조직은 Databricks의 `ucode`로 사용자 OAuth 로그인,
모델 검색, Claude 설정을 자동화할 수 있습니다.

```bash
uv tool install git+https://github.com/databricks/ucode
ucode claude
```

`ucode`는 Python 3.12 이상과 `uv`가 필요합니다.

## 9. 이전 LiteLLM 구성에서 마이그레이션

최신 자동 설정 스크립트를 실행하면:

- Base URL을 Databricks 네이티브 Anthropic API로 변경
- 기존 로컬 프록시 credential 제거
- `ANTHROPIC_SMALL_FAST_MODEL`을 Haiku 프리셋으로 이관한 뒤 deprecated key 제거
- launchd, systemd, Scheduled Task의 이전 프록시 자동 시작 중지
- 기존 LiteLLM 파일은 자동 삭제하지 않음

직접 연결을 확인한 뒤 다음 레거시 파일을 정리할 수 있습니다.

macOS/Linux:

```bash
rm -rf ~/.claude-databricks/.venv
rm -f ~/.claude-databricks/config.yaml
rm -f ~/.claude-databricks/custom_handlers.py
rm -f ~/.claude-databricks/start-proxy.sh
rm -f ~/.claude-databricks/proxy.log
```

Windows:

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

직접 연결에서도 사용하는 `.env`와 `get-token.*`은 삭제하지 않습니다.

## 10. Databricks 직접 연결 제거

Claude Code를 설치 전 상태로 되돌릴 때는 다음 순서를 사용합니다.

1. 실행 중인 Claude Code 세션 종료
2. [백업에서 복원](#백업에서-복원) 절차로 설치 직전 settings 복원
3. 더 이상 필요하지 않은 helper와 credential 제거
4. 기존 workspace를 유지한다면 해당 PAT를 workspace UI에서 폐기

macOS/Linux:

```bash
# 다른 Claude settings가 사용하지 않을 때만 삭제
rm -rf "$HOME/.claude-databricks"
rm -f .env
```

Windows PowerShell:

```powershell
Remove-Item "$HOME\.claude-databricks" -Recurse -Force `
    -ErrorAction SilentlyContinue
Remove-Item .env -Force -ErrorAction SilentlyContinue
```

리포 로컬 `settings.local.json`을 사용했다면 그 파일을 복원하거나, 설치 전에 파일이
없었고 다른 로컬 설정도 없다면 삭제합니다. 백업이 없거나 설치 후 settings를 수정했다면
파일 전체를 덮어쓰지 말고 Databricks `ANTHROPIC_*`, `apiKeyHelper`,
`availableModels`, `enforceAvailableModels`, `WebSearch` deny 변경을 검토해 병합하세요.

Workspace를 삭제하면 그 workspace의 PAT는 더 이상 유효하지 않지만 로컬 파일은 자동
삭제되지 않습니다. 기존 workspace를 유지하는 경우에는 로컬 파일 삭제만으로 PAT가
폐기되지 않으므로 UI에서 token을 명시적으로 revoke합니다. 기본 state directory를
다른 Claude settings도 참조한다면 전체 디렉터리 대신 더 이상 쓰지 않는 credential만
선별해 제거합니다.

## 11. 문제 해결

| 증상 | 원인 / 해결 |
| --- | --- |
| 지원하지 않는 beta/필드 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` 확인 |
| `401 Credential was not sent` | `apiKeyHelper` command와 token 파일 권한 확인 |
| 다른 key로 인증됨 | 셸과 프로필의 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY` 제거 |
| `403 ... rate limit of 0` | 모델·리전, cross-Geo, endpoint/사용자 rate limit, 권한, 계정 용량 확인 |
| `/ai-gateway/...` 실패 | Unity AI Gateway Preview, Unity Catalog, 리전, model service 권한 확인 |
| `/model`의 모델 실패 | 실제 endpoint ID와 리전 가용성 확인 |
| Fable이 picker에 없음 | Endpoint 검증 실패 또는 Claude Code 최소 버전 미충족 |
| `web_search_*` 400 | Bare `WebSearch` deny 또는 별도 MCP 검색 사용 |
| HTTP 200이지만 `type: "message"`가 없음 | Anthropic 경로, Claude 모델 ID, gateway의 응답 변형 여부 확인 |
| MCP tool search/Remote Control 없음 | Custom base URL의 기본 제한 |
| 포트 4000 listener가 남음 | 이전 LiteLLM PID를 확인한 뒤 해당 PID만 종료 |

macOS에서 이전 listener 확인:

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN
```

## 공식 문서

- [Provider native APIs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/provider-native-apis)
- [Query with the Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Foundation model Unity Catalog permissions](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/model-uc-permissions)
- [OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)
- [Databricks CLI authentication](https://learn.microsoft.com/azure/databricks/dev-tools/cli/authentication)
- [Personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [`tokens` command group](https://learn.microsoft.com/azure/databricks/dev-tools/cli/reference/tokens-commands)
- [Per-workspace URLs](https://learn.microsoft.com/azure/databricks/workspace/per-workspace-urls)
- [Unity AI Gateway coding-agent integration](https://learn.microsoft.com/azure/databricks/ai-gateway/coding-agent-integration-model-services)
- [Unity AI Gateway model provider service integration](https://learn.microsoft.com/azure/databricks/ai-gateway/coding-agent-integration-model-provider-services)
- [Unity AI Gateway Coding CLI (`ucode`)](https://github.com/databricks/ucode)
- [Claude Code settings scopes](https://code.claude.com/docs/en/settings#configuration-scopes)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
