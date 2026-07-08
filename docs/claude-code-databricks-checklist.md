# Claude Code × Azure Databricks (Anthropic Claude) 연결 — 요건 & 주의사항

로컬 [Claude Code](https://code.claude.com/) CLI의 백엔드를 Azure Databricks Model
Serving에 배포된 **Anthropic Claude**로 연결할 때 미리 알아둘 **요건과 함정**을
정리한 공유용 문서입니다. 동료·고객·파트너에게 사전 안내하는 용도로 그대로 전달할 수
있습니다.

> 실제 설치 방법과 수동 구성은 [`claude-code-databricks.md`](./claude-code-databricks.md),
> 원클릭 설치는 [`scripts/setup_claude_code_databricks.sh`](../scripts/setup_claude_code_databricks.sh)
> (Windows는 `.ps1`)를 참고하세요.

---

## TL;DR — 미리 알면 좋은 3가지

1. **Databricks 계정에 Anthropic이 "엔타이틀"돼 있어야 함** — 신규 계정은 기본 차단
   (`rate limit of 0`). 고객 설정으로 못 풀며 Databricks account team이 켜줘야 함.
2. **환경변수만으론 연결 불가** — Anthropic ↔ OpenAI 형식이 달라 중간에서 번역하는
   **LiteLLM 프록시**가 반드시 필요.
3. **⭐ LLM 분류기(small/fast 모델)가 조용히 실패할 수 있음** — 아래 별도 섹션 참고.

---

## 아키텍처

```
Claude Code ──(Anthropic /v1/messages)──► LiteLLM 프록시 ──(OpenAI /invocations)──► Azure Databricks
 (settings.json env)                       127.0.0.1:4000                            Claude 엔드포인트
```

Claude Code는 **Anthropic Messages API 형식만** 사용하고, Databricks 서빙 엔드포인트는
**OpenAI Chat Completions** 스키마입니다. Databricks `/invocations`는 Anthropic 형식으로
보내도 **OpenAI 형식으로 응답**하므로, 사이에서 형식을 번역하는 프록시가 필수입니다.

---

## ⭐ 1. LLM 분류기(small/fast model) — 가장 놓치기 쉬운 부분

Claude Code는 메인 대화 모델 외에, **가벼운 백그라운드 작업**(대화 요약·제목 생성·
**주제 분류(classification)**·컨텍스트/쿼터 판단 등)에 별도의 **small/fast 모델**을
사용합니다. 이 모델을 `ANTHROPIC_SMALL_FAST_MODEL`로 지정하며, 흔히
**"분류기(classifier)"**라고 부릅니다. (원래 Haiku급 경량 모델용으로 설계됨.)

Databricks 연결 시 **두 가지 함정**이 있습니다.

| # | 함정 | 증상 | 대응 |
| --- | --- | --- | --- |
| A | **catch-all 라우팅** | 프록시 `config.yaml`의 와일드카드 `*`가 **모든** 모델명을 메인 엔드포인트로 보냄 → 분류기가 의도와 달리 **무겁고 비싼 메인(예: Opus)** 으로 감 | 분류기 모델을 `config.yaml`에 **명시 엔트리**로 등록(예: `databricks-claude-haiku-4-5`) |
| B | **`stop_sequences` 거부** | 분류기/백그라운드 호출이 Anthropic `stop_sequences`를 보내는데 Databricks가 `Cannot specify parameter stop_sequences, use stop instead`로 **400 거부** → 분류기가 **조용히 실패**(백그라운드라 표면에 잘 안 드러남) | 프록시 프리콜 훅에서 **`stop_sequences` → `stop` 변환**(+ 공백-only 시퀀스 제거) |

> ⚠️ B는 메인 모델에도 동일하게 발생합니다. 분류기는 백그라운드라 실패해도 티가 잘
> 나지 않아 **"분류기만 이상하다"**처럼 보이기 쉽지만, 실제 원인은 파라미터 비호환입니다.
>
> ⚠️ `ANTHROPIC_SMALL_FAST_MODEL`은 **Claude Code 시작 시 로드**됩니다 → 바꾸면
> **Claude Code를 재시작**해야 반영됩니다.

---

## 2. Databricks 사전 요건 (가장 큰 진입 장벽)

- **계정 단위 Anthropic 엔타이틀먼트**: 신규 Databricks 계정은 Claude가
  **기본 비활성(`rate limit of 0`, 403)**입니다. 리전·워크스페이스 무관
  (**테넌트당 Databricks 계정 1개**)이고, partner-powered/cross-Geo 설정으로도 풀리지
  않으며, **고객 설정으로 해결 불가** → **Databricks account team이 활성화**해야 합니다.
  (Databricks 오픈 모델 Llama는 200인데 Claude만 403이면 이 상황입니다.)
- **Claude 서빙 엔드포인트 배포**(예: `databricks-claude-opus-4-8`) — pay-per-token
  (예: 200,000 ITPM 한도).
- **PAT**(Personal Access Token) — 대상 엔드포인트에 **CAN QUERY** 권한. Premium SKU 권장.

---

## 3. 프로토콜/파라미터 비호환 (프록시 훅에서 처리)

프록시의 `custom_handlers.py`(`async_pre_call_hook`)가 처리해야 하는 항목:

- **`thinking_blocks` / `reasoning_content`**: Claude Code(extended thinking)가 이력에
  재전송 → Databricks가 `messages.N.thinking_blocks: Extra inputs are not permitted`로
  거부 → **제거**.
- **`stop_sequences`**: 위 1-B → **`stop`으로 변환**.
- 그 외 미지원 파라미터는 LiteLLM `drop_params: true`로 무시.

---

## 4. Claude Code 설정 (`~/.claude/settings.json`의 `env`)

| 키 | 값 | 비고 |
| --- | --- | --- |
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:4000` | 로컬 프록시 주소 |
| `ANTHROPIC_AUTH_TOKEN` | 프록시 로컬 키 | `config.yaml`의 `master_key`와 **일치**(클라우드 비밀 아님). 활성인 동안 claude.ai 구독 대신 프록시 사용 |
| `ANTHROPIC_MODEL` | 메인 엔드포인트 | `config.yaml`의 `databricks/<endpoint>`와 이름 일치 |
| `ANTHROPIC_SMALL_FAST_MODEL` | **분류기용 경량 모델** | Haiku 권장. `config.yaml`에 명시 엔트리 필요(1-A) |

> **여러 모델 선택/전환**: 설치기는 선택 가능한 메인 모델(기본 **Opus 4.8 · Sonnet 5 ·
> Haiku 4.5**, 모두 최신)을 `config.yaml`에 모두 등록합니다. 그래서 Claude Code 안에서
> **`/model <이름>`**으로 실행 중 전환할 수 있습니다(예: `/model databricks-claude-sonnet-5`).
> `ANTHROPIC_MODEL`은 시작 시 기본값일 뿐이며, 등록 목록은 `DATABRICKS_MODELS`로 바꿉니다.
> ⚠️ catch-all은 **등록된** 모델명만 올바로 라우팅하므로 전환 대상은 반드시 등록돼 있어야 합니다.

> **상태줄(status line)**: 설치기가 Claude Code 하단에 모델 이름 옆으로 `[Databricks]` 배지 +
> 전체 엔드포인트 id를 표시해 Databricks 모델을 다른 모델과 한눈에 구분합니다
> (`~/.claude/statusline-databricks.py`, 기존 `statusLine`은 보존, `STATUSLINE=0`으로 끄기).

---

## 5. 프록시 운영 주의

- `config.yaml`/`.env`를 바꾼 뒤에는 **프록시 재시작** 필요(프로세스는 시작 시점에만 읽음).
- **자동시작(launchd/systemd/작업 스케줄러) + 수동 실행 동시 금지** → 포트 4000 충돌
  (`Address already in use`). 한 번에 하나만.
- 프록시는 `127.0.0.1`(로컬호스트)에만 바인딩되어 외부 접근 불가.
- **비밀(Databricks PAT)은 `.env`(권한 0600)에만** 두고 커밋 금지. 이상 시 `proxy.log`부터 확인.
- 도구 호출·스트리밍은 LiteLLM이 Anthropic↔OpenAI로 번역 — 대부분 정상이나 드물게 엣지 케이스.

---

## 최종 체크리스트

- [ ] Databricks 계정에 Anthropic 활성화됨 (오픈 모델 Llama는 되는데 Claude만 403이면 미활성)
- [ ] Claude 엔드포인트 배포 + CAN QUERY PAT 확보
- [ ] LiteLLM 프록시 구동 + 훅에서 `thinking_blocks` 제거 / `stop_sequences` → `stop` 변환
- [ ] **분류기 모델을 `config.yaml`에 명시 등록**(catch-all 회피) + `ANTHROPIC_SMALL_FAST_MODEL` 지정
- [ ] (선택) **여러 메인 모델 등록**(Opus 4.8 · Sonnet 5 · Haiku 4.5) → Claude Code `/model <이름>`으로 전환
- [ ] `settings.json` env 구성 후 **Claude Code 재시작**
- [ ] `stop_sequences` 포함 요청으로 메인·분류기 왕복 검증(둘 다 `type:"message"` 응답)
