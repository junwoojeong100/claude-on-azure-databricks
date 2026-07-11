# Claude Code × Azure Databricks — 요건 & 주의사항

로컬 Claude Code를 Azure Databricks-hosted Claude에 연결할 때 필요한 요건과 운영
주의사항을 정리한 공유용 체크리스트입니다.

> 최종 검증: 2026-07-11, Claude Code 2.1.207.

> 실제 설치는 [`claude-code-databricks.md`](./claude-code-databricks.md),
> 자동 설정은 [`scripts/setup_claude_code_databricks.sh`](../scripts/setup_claude_code_databricks.sh)
> 또는 Windows `.ps1`을 참고하세요.

---

## TL;DR

1. Azure Databricks는 현재 **네이티브 Anthropic Messages API**를 제공합니다.
2. Claude Code는 `/serving-endpoints/anthropic`에 직접 연결할 수 있습니다.
3. **LiteLLM 프록시, 로컬 포트, 백그라운드 서비스가 필요하지 않습니다.**
4. Claude Code가 보내는 미지원 beta 헤더를 막기 위해
   `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`을 사용합니다.
5. Anthropic hosted `WebSearch`는 현재 Databricks 네이티브 경로에서 지원이 문서화돼
   있지 않고 실제 `web_search_20250305` 호출도 거부되므로 bare
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
  - Sonnet 프리셋: `databricks-claude-sonnet-5`
  - Haiku/경량 백그라운드: `databricks-claude-haiku-4-5`
  - Fable 후보: `databricks-claude-fable-5` (현재 workspace에서 실제 호출이 성공할 때만 매핑)
- 모델 호출 권한이 있는 Databricks 인증 정보
  - 개발: PAT(legacy; 가능하면 서비스 주체 PAT)
  - 운영: OAuth M2M 권장
- 일반 endpoint ACL의 `CAN QUERY`; Foundation Model UC 권한 기능 사용 시 대상
  `system.ai` 모델의 `EXECUTE`
- Claude Code CLI 2.1.197 이상 권장(Sonnet 5 기준)
- macOS/Linux 설치기: `curl`과 Python 3
- Windows 설치기: Windows PowerShell 5.1 이상 또는 PowerShell 7

Anthropic 모델 호출이 `403 ... rate limit of 0`으로 거부되면 README의 모델/리전,
cross-Geo, rate limit, 권한, 계정 용량 점검 순서를 확인합니다.

> Fable 5의 프롬프트와 응답은 trust and safety 목적으로 30일 보존되며 자동 안전
> 시스템과 일부 경우 사람 검토의 대상이 될 수 있습니다. 안전 조사나 법적 요구 시
> 더 오래 보존될 수 있습니다. 설치기 기본 후보에도 Fable 5가 포함되므로
> [공식 모델 정책](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models#claude-fable-5)을
> 먼저 검토하세요. 승인되지 않은 워크로드에서는 `DATABRICKS_MODELS`를 Fable을 제외한
> 목록으로 설정하세요.

---

## 2. 필수 Claude Code 설정

| 설정 | 값 / 역할 |
| --- | --- |
| `ANTHROPIC_BASE_URL` | `https://<workspace>/serving-endpoints/anthropic` |
| `apiKeyHelper` | 보호된 파일 또는 OAuth helper에서 Databricks 토큰 반환 |
| `ANTHROPIC_MODEL` | 기본 Claude 모델 |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` | `/model`의 Opus/Sonnet 프리셋 매핑 |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Haiku 프리셋과 세션 제목 생성 등 경량 백그라운드 모델 |
| `ANTHROPIC_DEFAULT_FABLE_MODEL` | Fable endpoint가 실제 검증된 경우에만 설정 |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | `1`; 미지원 beta 헤더와 beta 도구 스키마 필드 제거 |
| `permissions.deny` | 기존 규칙을 보존하고 bare `WebSearch` 추가 |

> PAT를 `ANTHROPIC_AUTH_TOKEN`으로 `settings.json`에 직접 저장하지 않는 것을
> 권장합니다. 자동 설정 스크립트는 0600 파일과 `apiKeyHelper`를 사용합니다.

> Claude Code 2.1.207 검증에서 auto 권한 모드의 LLM 분류기는
> `ANTHROPIC_DEFAULT_HAIKU_MODEL`이 아닌 현재 메인 모델을 사용했습니다.
> deprecated `ANTHROPIC_SMALL_FAST_MODEL`은 설정하지 않아도 됩니다.

> 자동 설정기는 PAT helper만 생성합니다. OAuth M2M은 별도 단기 토큰 helper가 필요합니다.
> Opus/Sonnet은 검증된 같은 family 후보를 우선하고 없으면 기본 모델로 fallback합니다.
> Haiku 검증이 실패하면 같은 기본 모델을 사용하며 `DATABRICKS_MODELS`의 다른 Haiku
> 후보를 자동 선택하지 않습니다.
> Fable은 다른 family로 조용히 대체하지 않으며, 검증에 실패하면 mapping을 만들지 않습니다.
> custom `ANTHROPIC_BASE_URL`에서는 MCP tool search와 Remote Control이 기본
> 비활성화됩니다. 일반 MCP 서버 사용과는 별개입니다.

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
- Fable endpoint는 리전·계정별 가용성을 검증한 뒤에만 mapping

Anthropic hosted `web_search_20250305`는 실제 호출에서 HTTP 400으로 거부됨을
확인했습니다. Claude Code 버전에 따라 hosted tool 버전 문자열은 달라질 수 있습니다.
이는 일반적인 로컬 `tool_use` 지원과 별개이며, 설치 스크립트가 `WebSearch`를 모델
컨텍스트에서 제거합니다.

Python Agent Framework는 Claude Code와 별개입니다. Agent Framework가 대화 이력에
추가하는 OpenAI `name` 필드를 Databricks Claude가 거부하므로
`src/agent_sample.py`에는 그 필드만 제거하는 최소 httpx 훅이 남아 있습니다.

---

## 4. 두 AI Gateway와의 차이

| 경로/기능 | 상태 | 용도 |
| --- | --- | --- |
| `/serving-endpoints/anthropic` | 이 리포의 직접 연결 | Databricks-hosted Claude 네이티브 API |
| Serving endpoint의 **AI Gateway** | 이전 세대 endpoint 기능 | usage tracking, rate limit, payload logging, guardrail |
| `/ai-gateway/anthropic` | Unity AI Gateway Beta | Unity Catalog model service, 예산, service policy, routing, 통합 관측 |

Unity AI Gateway Beta는 **필수 조건이 아닙니다**. Preview가 꺼져 있어도
`/serving-endpoints/anthropic` 직접 연결은 사용할 수 있습니다. 이전 세대 endpoint
gateway에서 pay-per-token endpoint의 fallback/traffic splitting은 지원되지 않으므로
새 Unity AI Gateway routing 기능과 구분합니다.

Beta가 활성화된 환경에서는 Databricks `ucode`가 사용자 OAuth와 Claude 설정을
자동화합니다. Python 3.12 이상과 `uv`가 필요합니다.

```bash
uv tool install git+https://github.com/databricks/ucode
ucode claude
```

---

## 5. 이전 LiteLLM 사용자

최신 자동 설정 스크립트를 실행하면:

- Claude Code를 네이티브 Anthropic URL로 전환
- 기존 로컬 프록시 키 제거
- 기존 `ANTHROPIC_SMALL_FAST_MODEL` 값을 Haiku 프리셋으로 이관한 뒤 deprecated key 제거
- launchd/systemd/Scheduled Task 비활성화
- 기존 LiteLLM 파일은 안전을 위해 자동 삭제하지 않음

직접 연결을 확인한 뒤 `.venv`, `config.yaml`, `custom_handlers.py`,
`start-proxy.*`, `proxy.log`를 삭제할 수 있습니다. 새 `apiKeyHelper`가 사용하는
`.env`와 `get-token.*`은 유지합니다.

---

## 최종 체크리스트

- [ ] Databricks Claude 모델을 직접 호출할 수 있음
- [ ] Claude Code 2.1.197 이상 또는 선택 모델별 최소 버전 확인
- [ ] `ANTHROPIC_BASE_URL`이 `/serving-endpoints/anthropic`을 가리킴
- [ ] 토큰이 `settings.json`이 아닌 보호된 helper 파일 또는 OAuth로 제공됨
- [ ] 셸/프로필에 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`가 남아 있지 않음
- [ ] `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`
- [ ] `permissions.deny`에 bare `WebSearch`가 있음
- [ ] Haiku 경량 백그라운드 모델과 `/model` 프리셋 매핑 확인
- [ ] Fable 사용 시 endpoint 검증과 30일 보존·사람 검토 정책 승인 완료
- [ ] Claude Code 단일/다중 턴 검증
- [ ] custom base URL에서 Remote Control/MCP tool search 제한을 인지함
- [ ] 이전 LiteLLM 자동 시작 서비스 중지
- [ ] 운영 환경은 PAT 대신 OAuth M2M 검토
