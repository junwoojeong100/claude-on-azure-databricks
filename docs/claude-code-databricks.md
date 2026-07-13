# Claude Code에서 Azure Databricks Claude 사용하기

이 가이드는 Azure Databricks workspace에서 Anthropic Claude 모델을 이미 호출할 수 있는
사용자를 위한 것입니다.

```text
Claude Code
  └─ https://<workspace-host>/serving-endpoints/anthropic/v1/messages
```

> 최종 검증: 2026-07-13, Claude Code 2.1.207,
> `databricks-claude-opus-4-8`.

## 1. 필요한 값

| 값 | 예 |
| --- | --- |
| Workspace URL | `https://adb-1234567890123456.7.azuredatabricks.net` |
| Claude 모델 ID | `databricks-claude-opus-4-8` |
| PAT | 해당 workspace와 모델을 호출할 수 있는 token |

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

## 2. 한 파일로 설정

프로젝트 루트의 `.claude/settings.local.json`에 workspace URL, PAT, 모델 ID를
입력합니다. 이 파일은 이 리포의 `.gitignore`에 포함됩니다.

[최소 수동 설정 가이드](claude-code-databricks-manual.md)의 JSON을 그대로 사용하세요.

핵심 설정:

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`
- `permissions.deny`의 `WebSearch`

`availableModels`와 `ANTHROPIC_DEFAULT_*_MODEL` 값만으로 `/model` 선택기의
Opus/Sonnet/Haiku 항목과 실제 Databricks 모델 mapping이 구성됩니다. 자동 스크립트는
필요하지 않습니다.

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

`/model`에서 Databricks 모델과 Opus/Sonnet/Haiku alias를 확인할 수 있습니다.

## 4. 모델 전환

```text
/model
```

또는 시작할 때 모델 ID를 지정합니다.

```bash
claude --model databricks-claude-sonnet-5
```

모델 ID는 현재 workspace에서 실제 호출 가능한 값이어야 합니다.

## 5. 자주 발생하는 문제

| 증상 | 확인할 항목 |
| --- | --- |
| `401 Credential was not sent` | settings의 PAT와 workspace URL |
| 다른 provider나 host가 사용됨 | 터미널의 `ANTHROPIC_*`, `CLAUDE_CODE_USE_*` 환경변수 제거 |
| beta 관련 400 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` |
| `web_search_*` 관련 400 | `permissions.deny`의 `WebSearch` |
| 모델을 찾지 못함 | 실제 모델 ID와 리전 가용성 |
| `403 ... rate limit of 0` | 모델·리전, rate limit, `CAN QUERY`/`EXECUTE`, 계정 용량 |

## 선택: credential 보안 강화

한 파일 방식은 PAT를 평문으로 저장합니다. 보안 요구가 높아지면 다음 공식 인증 방식을
검토하세요.

- [OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)
- [OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
