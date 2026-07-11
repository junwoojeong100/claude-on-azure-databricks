# Claude Code × Azure Databricks 체크리스트

다른 사용자에게 Claude Code 직접 연결을 설명하거나 배포 전에 검토할 때 사용하는
요약 문서입니다.

실제 설정:

- [자동·수동 연결 가이드](claude-code-databricks.md)
- [인증·모델·gateway 상세 참고](claude-code-databricks-reference.md)

> 최종 검증: 2026-07-12, Claude Code 2.1.207.

## 핵심 메시지

1. Azure Databricks는 Claude용 네이티브 Anthropic Messages API를 제공합니다.
2. Claude Code의 `ANTHROPIC_BASE_URL`을 `/serving-endpoints/anthropic`으로 설정합니다.
3. LiteLLM, 로컬 포트, 백그라운드 프록시는 필요하지 않습니다.
4. Token은 `settings.json`에 넣지 않고 `apiKeyHelper`로 제공합니다.
5. 미지원 beta와 hosted `WebSearch`를 비활성화합니다.

```text
Claude Code ──(Anthropic /v1/messages)──► Azure Databricks
                                           /serving-endpoints/anthropic
```

## 사전 요건

- [ ] 지원 리전의 Azure Databricks workspace
- [ ] 호출 가능한 Databricks-hosted Claude 모델
- [ ] Endpoint `CAN QUERY`
- [ ] Foundation Model UC 권한 사용 시 대상 `system.ai` 모델 `EXECUTE`
- [ ] 로컬 테스트용 PAT 또는 운영용 OAuth M2M
- [ ] Claude Code 최소 버전 확인
  - Opus 4.8: 2.1.154+
  - Fable 5: 2.1.170+
  - Sonnet 5: 2.1.197+

## 필수 설정

- [ ] `ANTHROPIC_BASE_URL=https://<workspace>/serving-endpoints/anthropic`
- [ ] `ANTHROPIC_DEFAULT_OPUS_MODEL`
- [ ] `ANTHROPIC_DEFAULT_SONNET_MODEL`
- [ ] `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- [ ] `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`
- [ ] `permissions.deny`에 bare `WebSearch`
- [ ] `availableModels`가 검증된 Databricks alias/ID만 포함
- [ ] `enforceAvailableModels=true`
- [ ] Token을 보호된 helper 파일 또는 OAuth helper로 제공
- [ ] 셸/프로필의 기존 `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY` 제거
- [ ] Deprecated된 `ANTHROPIC_SMALL_FAST_MODEL` 제거
- [ ] `ANTHROPIC_MODEL`을 중복 설정하지 않음

## 검증

- [ ] `/serving-endpoints/anthropic/v1/messages`가 `type: "message"` 반환
- [ ] Claude Code 단일 턴 성공
- [ ] Claude Code 다중 턴 성공
- [ ] `/model`에서 Opus/Sonnet/Haiku 프리셋 확인
- [ ] 일반 Claude Code 도구 호출 성공
- [ ] hosted `WebSearch`가 모델에 노출되지 않음
- [ ] 이전 LiteLLM 자동 시작 서비스가 중지됨

## 보안·운영 확인

- [ ] `.env`와 token helper 파일이 Git에 포함되지 않음
- [ ] 운영 환경은 PAT 대신 서비스 주체 OAuth M2M 검토
- [ ] Fable 5 사용 시 30일 보존과 일부 사람 검토 정책 승인
- [ ] Custom base URL에서 MCP tool search와 Remote Control 제한 인지
- [ ] Unity AI Gateway와 serving endpoint AI Gateway를 구분
- [ ] 모델·리전, cross-Geo, rate limit, 계정 용량 변경 가능성 검토

## 문제 발생 시 우선순위

1. 다른 Anthropic credential이 환경에 남아 있는지 확인
2. 네이티브 API를 `curl`로 직접 호출
3. 모델 ID와 리전 가용성 확인
4. `CAN QUERY`/`EXECUTE`와 rate limit 확인
5. Claude Code settings와 `apiKeyHelper` 확인
