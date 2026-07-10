# Claude Code × Azure Databricks — 요건 & 주의사항

로컬 Claude Code를 Azure Databricks-hosted Claude에 연결할 때 필요한 요건과 운영
주의사항을 정리한 공유용 체크리스트입니다.

> 실제 설치는 [`claude-code-databricks.md`](./claude-code-databricks.md),
> 자동 설정은 [`scripts/setup_claude_code_databricks.sh`](../scripts/setup_claude_code_databricks.sh)
> 또는 Windows `.ps1`을 참고하세요.

---

## TL;DR

1. Azure Databricks는 현재 **네이티브 Anthropic Messages API**를 제공합니다.
2. Claude Code는 `/serving-endpoints/anthropic`에 직접 연결할 수 있습니다.
3. **LiteLLM 프록시, 로컬 포트, 백그라운드 서비스가 필요하지 않습니다.**
4. Claude Code가 보내는 미지원 beta 헤더를 막기 위해
   `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`이 필요합니다.
5. Anthropic hosted `WebSearch`는 Databricks가 지원하지 않으므로 bare
   `permissions.deny: ["WebSearch"]`로 숨기고, 필요하면 MCP 검색을 사용합니다.

```text
Claude Code ──(Anthropic /v1/messages)──► Azure Databricks
                                           /serving-endpoints/anthropic
```

---

## 1. Databricks 사전 요건

- 지원 리전의 Azure Databricks 워크스페이스
- Databricks-hosted Claude 모델
  - 기본: `databricks-claude-opus-4-8`
  - small/fast: `databricks-claude-haiku-4-5`
- 모델 호출 권한이 있는 Databricks 인증 정보
  - 개발: PAT
  - 운영: OAuth M2M 권장
- Claude Code CLI

Anthropic 모델 호출이 `403 ... rate limit of 0`으로 거부되면 README의 문제 해결 절을
먼저 확인합니다.

---

## 2. 필수 Claude Code 설정

| 설정 | 값 / 역할 |
| --- | --- |
| `ANTHROPIC_BASE_URL` | `https://<workspace>/serving-endpoints/anthropic` |
| `apiKeyHelper` | 보호된 파일 또는 OAuth helper에서 Databricks 토큰 반환 |
| `ANTHROPIC_MODEL` | 기본 Claude 모델 |
| `ANTHROPIC_SMALL_FAST_MODEL` | 요약·분류 등 백그라운드 모델 |
| `ANTHROPIC_DEFAULT_*_MODEL` | `/model`의 Opus/Sonnet/Haiku 프리셋 매핑 |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | 반드시 `1`; 미지원 beta 헤더 방지 |
| `permissions.deny` | 기존 규칙을 보존하고 bare `WebSearch` 추가 |

> PAT를 `ANTHROPIC_AUTH_TOKEN`으로 `settings.json`에 직접 저장하지 않는 것을
> 권장합니다. 자동 설정 스크립트는 0600 파일과 `apiKeyHelper`를 사용합니다.
> 선택 모델 검증이 실패한 family는 검증된 기본 또는 small/fast 모델로 fallback합니다.

---

## 3. 직접 연결 검증 항목

현재 구성에서 다음 항목을 LiteLLM 없이 검증했습니다.

- Anthropic `type:"message"` 응답
- Claude Code 단일 턴
- 대화 이력을 재사용하는 다중 턴
- high effort
- `stop_sequences`
- Anthropic `tool_use`
- Opus/Sonnet/Haiku 모델 ID 전달

Anthropic hosted `web_search_20250305`는 실제 호출에서 HTTP 400으로 거부됨을 확인했습니다.
이는 일반적인 로컬 `tool_use` 지원과 별개이며, 설치 스크립트가 `WebSearch`를 모델 컨텍스트에서
제거합니다.

Python Agent Framework는 Claude Code와 별개입니다. Agent Framework가 대화 이력에
추가하는 OpenAI `name` 필드를 Databricks Claude가 거부하므로
`src/agent_sample.py`에는 그 필드만 제거하는 최소 httpx 훅이 남아 있습니다.

---

## 4. Unity AI Gateway와의 차이

| 경로 | 상태 | 용도 |
| --- | --- | --- |
| `/serving-endpoints/anthropic` | 현재 기본 | Databricks-hosted Claude 네이티브 API |
| `/ai-gateway/anthropic` | Unity AI Gateway Beta (v2 API) | Unity Catalog 권한, 예산, guardrail, fallback, 통합 관측 |

Unity AI Gateway Beta는 **필수 조건이 아닙니다**. v2 API가 `404 FEATURE_DISABLED`여도
`/serving-endpoints/anthropic` 직접 연결은 사용할 수 있습니다.

Beta가 활성화된 환경에서는 Databricks `ucode`가 OAuth와 Claude 설정을 자동화합니다.

```bash
uv tool install git+https://github.com/databricks/ucode
ucode claude
```

---

## 5. 이전 LiteLLM 사용자

최신 자동 설정 스크립트를 실행하면:

- Claude Code를 네이티브 Anthropic URL로 전환
- 기존 로컬 프록시 키 제거
- launchd/systemd/Scheduled Task 비활성화
- 기존 LiteLLM 파일은 안전을 위해 자동 삭제하지 않음

직접 연결을 확인한 뒤 `.venv`, `config.yaml`, `custom_handlers.py`,
`start-proxy.*`, `proxy.log`를 삭제할 수 있습니다. 새 `apiKeyHelper`가 사용하는
`.env`와 `get-token.*`은 유지합니다.

---

## 최종 체크리스트

- [ ] Databricks Claude 모델을 직접 호출할 수 있음
- [ ] `ANTHROPIC_BASE_URL`이 `/serving-endpoints/anthropic`을 가리킴
- [ ] 토큰이 `settings.json`이 아닌 보호된 helper 파일 또는 OAuth로 제공됨
- [ ] 셸/프로필에 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`가 남아 있지 않음
- [ ] `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`
- [ ] `permissions.deny`에 bare `WebSearch`가 있음
- [ ] small/fast 모델과 `/model` 프리셋 매핑 확인
- [ ] Claude Code 단일/다중 턴 검증
- [ ] 이전 LiteLLM 자동 시작 서비스 중지
- [ ] 운영 환경은 PAT 대신 OAuth M2M 검토
