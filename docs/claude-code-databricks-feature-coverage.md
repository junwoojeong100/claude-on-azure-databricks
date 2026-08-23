# Azure Databricks Claude 연결 시 Claude Code 기능 커버리지

Claude Code의 모델 백엔드만 Azure Databricks의 Claude 모델로 바꾸었을 때 사용할 수
있는 기능과 제한되는 기능을 정리합니다.

```text
로컬 Claude Code
  ├─ 파일, 셸, Git, MCP, hooks, subagents 실행
  └─ Azure Databricks Anthropic Messages API
       └─ Claude 모델 추론
```

이 구조에서는 Claude Code의 agent harness와 도구가 로컬에 남고, 모델 추론 요청만
Databricks로 이동합니다. 따라서 로컬 코딩 기능은 대부분 유지되지만 Anthropic 계정,
claude.ai 또는 Anthropic의 서버 도구에 의존하는 기능은 사용할 수 없거나 별도 경로가
필요합니다.

> 검토 기준일: 2026-08-24. 아래 비율은 Anthropic이나 Microsoft가 보증하는 공식
> 호환성 수치가 아니라 공식 문서, 이 저장소의 기본 설정, 실제 연결 검증을 바탕으로 한
> 가중 평가입니다. Claude Code와 Databricks API가 변경되면 다시 검증해야 합니다.

## 결론

| 관점 | 예상 커버리지 | 의미 |
| --- | ---: | --- |
| 로컬 코딩 생산성 | **94%** | 코드 탐색, 수정, 명령 실행, 검증, 확장 기능 중심 |
| 전체 제품 기능 폭 | **78%** | claude.ai, 모바일, 원격 제어, Anthropic 서버 기능까지 포함 |
| 종합 참고치 | **88%** | 로컬 코딩 생산성 65%, 전체 제품 기능 폭 35%로 가중 |

일반적인 저장소 작업만 평가하면 **92~95%**를 사용할 수 있습니다. Claude Code의 모든
클라우드·협업 기능을 동일한 비중으로 평가하면 **75~80%** 수준입니다. 하나의 숫자가
필요할 때는 **약 88%**를 사용하되, 운영 의사 결정에는 아래 기능별 표를 사용해야 합니다.

## 완전히 또는 거의 그대로 사용할 수 있는 영역

| 영역 | 예상 지원 | 근거와 주의점 |
| --- | ---: | --- |
| 파일 읽기, 검색, 편집 | 100% | `Read`, `Glob`, `Grep`, `Edit`, `Write`, notebook 도구는 로컬에서 실행 |
| 셸, Git, 빌드, 테스트 | 100% | `Bash`, PowerShell과 하위 process는 로컬 환경에서 실행 |
| 기본 agent loop | 95% | 모델이 tool call을 반환하고 Claude Code가 실행 결과를 다시 보내는 구조 유지 |
| 세션, checkpoint, sandbox, worktree | 100% | 로컬 Claude Code runtime과 파일 시스템 기능 |
| `CLAUDE.md`, rules, auto memory | 100% | 로컬 project context로 Messages API 요청에 포함 |
| Skills, hooks, plugins | 95% | 로컬 확장 기능이며 모델 provider와 직접 결합되지 않음 |
| MCP client tools | 90~95% | MCP server 연결과 tool 실행은 가능. Tool search 최적화는 제한될 수 있음 |
| Subagents, agent teams, workflows | 90~95% | 각 agent가 같은 Databricks route를 사용. 병렬 호출 시 rate limit에 더 빨리 도달 |
| CLI, headless mode, Agent SDK | 95% | `ANTHROPIC_BASE_URL`과 credential이 자식 process에도 전달되어야 함 |
| VS Code와 JetBrains | 90~95% | IDE 자체 기능은 유지. extension 시작 전 credential 전달을 별도로 구성 |

Claude Code 공식 문서도 CLI, IDE extension, subagents, hooks, commands, skills,
`CLAUDE.md`, plugins, MCP, checkpoints, sandbox, workflows와 OpenTelemetry를 provider
공통 기능으로 분류합니다. Databricks는 Claude 모델에 네이티브 Anthropic Messages API를
제공하므로 OpenAI 호환 변환을 거치지 않고 이 로컬 기능들의 tool-use loop를 유지할 수
있습니다.

## 제한적으로 사용할 수 있는 영역

| 영역 | 예상 지원 | 제한 |
| --- | ---: | --- |
| Streaming | 90% | Messages API streaming이 필요하며 중간 proxy가 있다면 SSE와 keep-alive를 그대로 전달해야 함 |
| 이미지 입력 | 90% | Databricks Claude 모델은 이미지 입력을 지원하지만 request payload는 4MB로 제한 |
| Prompt caching | 80~90% | 기본 conversation cache breakpoint는 동작. Custom base URL에서는 일부 중간 system block이 매번 uncached input이 될 수 있음 |
| Adaptive reasoning과 thinking | 75~90% | 최신 Claude 모델은 지원하지만 모델별 요청 필드와 응답 block을 실제 검증해야 함 |
| 1M context selector | 50~70% | 모델 context는 1M이어도 pay-per-token ITPM과 4MB payload 제한 때문에 한 요청에서 모두 활용하기 어려움 |
| Auto mode | 70~90% | 최신 모델에서 동작할 수 있지만 Databricks는 Claude Code 공식 provider 표에 없으므로 권한 classifier 동작을 검증해야 함 |
| MCP tool search | 50~80% | Custom `ANTHROPIC_BASE_URL`에서는 기본적으로 꺼지고 beta tool field 지원 여부에 따라 달라짐 |
| `/loop`와 scheduled tasks | 70~90% | 명시적 로컬 interval은 사용 가능. claude.ai routine과 같은 원격 실행은 불가 |
| WebFetch | 70~90% | 특정 URL fetch는 로컬에서 수행하지만 domain safety check가 `api.anthropic.com`에 직접 접근할 수 있음 |
| GitHub Actions | 70~90% | Custom base URL과 Databricks credential을 workflow에 안전하게 전달하는 별도 설정 필요 |
| Desktop | 30~70% | 일반 CLI 설정이 아닌 Desktop의 third-party inference 또는 관리 설정이 필요 |

### 1M context의 실제 경계

`databricks-claude-opus-5`, Opus 4.8, Sonnet 5와 Sonnet 4.6은 1M context를 지원합니다.
그러나 Azure Databricks Enterprise-tier pay-per-token Claude 한도는 다음과 같습니다.

| 제한 | 값 |
| --- | ---: |
| Input tokens per minute | 200,000 |
| Output tokens per minute | 20,000 |
| Queries per hour | 360,000 |
| Request payload | 4MB |
| Workspace queries per second | 200 |

`[1m]` selector는 Claude Code가 context window를 1M으로 관리하도록 하지만 이 제한을
해제하지 않습니다. 큰 repository나 병렬 subagent 작업에서는 prompt caching,
`/compact`, 작은 tool result, 호출 간 backoff를 함께 사용해야 합니다. 지속적인 고부하
운영은 pay-per-token 대신 provisioned throughput을 검토합니다.

### 이 저장소의 안전 우선 설정

설정 도구는 다음 두 가지를 기본 적용합니다.

```json
{
  "permissions": {
    "deny": ["WebSearch"]
  },
  "env": {
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

- `WebSearch`를 차단해 Databricks가 지원하지 않는 Anthropic server tool 요청을 막습니다.
- Experimental beta를 꺼 context management와 beta tool schema field 때문에 발생할 수
  있는 `400`을 방지합니다.
- 대신 server-side tool-result clearing과 MCP tool search 같은 beta 최적화가
  비활성화될 수 있습니다.
- 로컬 `/compact`, client tool use, MCP server 연결 자체는 계속 사용할 수 있습니다.

Beta 기능을 다시 켤 때는 전체 사용자에게 배포하기 전에 별도 project 설정에서 context
management, deferred MCP tools, structured tool schema를 각각 검증해야 합니다.

## 사용할 수 없거나 별도 Anthropic 로그인이 필요한 영역

| 영역 | 상태 | 이유 또는 대안 |
| --- | --- | --- |
| Anthropic Web Search | 기본 미지원 | Anthropic server tool이며 이 저장소에서 명시적으로 차단. MCP 검색이나 특정 URL의 WebFetch 사용 |
| Fast mode | 미지원 | Anthropic API와 subscription 전용 speed tier |
| Advisor | 미지원 | Anthropic server-side capability |
| Channels | 미지원 | Anthropic 서비스 연결 필요 |
| Cross-session messaging | 미지원 | Anthropic 계정 또는 API 기능 필요. 한 session 내부 subagent는 사용 가능 |
| Remote Control | 미지원 | Custom `ANTHROPIC_BASE_URL`과 gateway credential 사용 시 비활성화 |
| Voice dictation | 미지원 | claude.ai identity와 transcription endpoint 필요 |
| Artifacts | 미지원 | claude.ai publish와 subscription login 필요. 로컬 HTML/Markdown 생성은 가능 |
| Claude Code web·mobile·Slack | 미지원 | Anthropic-hosted surface이며 gateway 환경변수를 사용하지 않음 |
| Routines와 `/schedule` | 미지원 | claude.ai에서 실행되는 원격 automation. 로컬 `/loop` interval로 일부 대체 |
| Ultrareview와 hosted Code Review | 미지원 | Claude subscription 및 Anthropic cloud 기능 |
| Chrome extension과 computer use | 미지원 | Claude subscription과 Anthropic 연결 필요 |
| Anthropic analytics dashboard | 미지원 | Databricks billing, system tables, AI Gateway usage tracking으로 대체 |
| Server-managed settings | 미지원 | Anthropic 조직 기능. MDM 또는 local managed settings file 사용 |

이 표의 “미지원”은 Databricks Claude 모델이 코딩을 수행하지 못한다는 뜻이 아닙니다.
해당 기능의 control plane이나 실행 환경이 Anthropic에 있기 때문에 Databricks token만으로
접근할 수 없다는 뜻입니다.

## 실제 연결 검증

2026-08-24에 Claude Code 2.1.241과 다음 조건으로 핵심 loop를 검증했습니다.

| 항목 | 결과 |
| --- | --- |
| Route | Azure Databricks native Anthropic Messages API |
| 선택 모델 | `databricks-claude-opus-4-8[1m]` |
| 요청 | `Glob`으로 `README.md` 검색 후 `Read`, 첫 Markdown heading 반환 |
| Tool calls | `Glob`, `Read`, `StructuredOutput` |
| Tool-result round trip | 성공 |
| 최종 응답 | README의 첫 heading과 일치 |
| Cache creation input | 47,328 tokens |
| Cache read input | 129,507 tokens |
| API 또는 schema 오류 | 없음 |

이 검증은 다음을 확인합니다.

1. Claude Code가 Databricks 모델로 요청을 보낼 수 있음
2. 모델이 client tool call을 생성할 수 있음
3. Claude Code가 로컬 도구를 실행하고 `tool_result`를 모델에 반환할 수 있음
4. 모델이 tool result를 사용해 최종 응답을 생성할 수 있음
5. Databricks 경로에서 Claude Code prompt caching이 실제 사용됨

다음 항목은 이 smoke test만으로 보증하지 않습니다.

- 파일 수정, Bash와 Git의 장시간 연속 실행
- 이미지 입력
- adaptive thinking과 interleaved thinking
- MCP tool search와 많은 MCP schema
- 병렬 subagents의 rate-limit 내구성
- 200K tokens를 넘는 단일 요청
- IDE, Desktop, CI surface별 credential 전달

## 운영 전 검증 체크리스트

| 우선순위 | 검증 |
| --- | --- |
| 필수 | `/status`에서 Databricks base URL과 credential source 확인 |
| 필수 | `modelUsage`에서 선택한 `databricks-claude-*` 모델 확인 |
| 필수 | `Read → Edit → test → 재수정`의 다중 turn agent loop 확인 |
| 필수 | Prompt cache read/write token과 Databricks 비용 확인 |
| 필수 | 429 응답의 backoff와 병렬 agent 호출 수 제한 확인 |
| 권장 | 이미지 하나를 포함한 Messages API 요청 확인 |
| 권장 | 사용하는 MCP server마다 discovery, tool call, 큰 tool result 확인 |
| 권장 | OAuth U2M 또는 M2M token 갱신 중 장시간 session 확인 |
| 선택 | Experimental beta를 켠 별도 환경에서 context management 확인 |

기본 모델 ID가 다른 provider의 deployment나 gateway alias로 남아 있으면 Databricks가
요청을 거부합니다. `ANTHROPIC_BASE_URL`만 바꾸는 것으로는 충분하지 않으며 `model`,
`ANTHROPIC_DEFAULT_*_MODEL`과 `/model` 선택값도 Databricks 모델 ID로 맞춰야 합니다.
또한 shell alias나 wrapper가 `claude` 실행 파일을 가로채지 않는지 확인합니다.

## 평가 방법

### 로컬 코딩 생산성 94%

실제 repository 작업 빈도를 기준으로 가중했습니다.

| 기능군 | 가중치 | 평가 |
| --- | ---: | ---: |
| 파일, 검색, 편집, 셸, Git, 테스트 | 45% | 100% |
| Agent loop, tool use, session 관리 | 25% | 95% |
| MCP, skills, hooks, plugins, subagents | 20% | 92% |
| Multimodal, long context, provider 최적화 | 10% | 65% |
| **합계** | **100%** | **93.7%** |

### 전체 제품 기능 폭 78%

모든 주요 기능군을 비슷한 중요도로 보고 claude.ai와 Anthropic server 기능까지
포함했습니다.

| 기능군 | 가중치 | 평가 |
| --- | ---: | ---: |
| Core local coding | 35% | 98% |
| Local extensions와 orchestration | 25% | 92% |
| Model API capability | 20% | 82% |
| Anthropic cloud, account, collaboration | 20% | 20% |
| **합계** | **100%** | **77.7%** |

종합 참고치는 두 관점을 `94 × 0.65 + 78 × 0.35 = 88.4`로 계산해 **88%**로
표시했습니다. 조직에서 Remote Control, web, mobile, Artifacts가 중요하면 78%에 가깝게,
터미널 기반 코딩만 중요하면 94%에 가깝게 평가해야 합니다.

## 공식 문서

- [Claude Code feature availability](https://code.claude.com/docs/en/feature-availability)
- [Claude Code gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)
- [Claude Code prompt caching](https://code.claude.com/docs/en/prompt-caching)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks Foundation Model API limits](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/limits)
- [Azure Databricks vision model inputs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-vision-models)
