# Claude on Azure Databricks

이 리포지토리는 서로 독립적인 두 가지 작업을 안내합니다.

| 현재 상태 | 시작할 가이드 | 완료 결과 |
| --- | --- | --- |
| Azure Databricks workspace가 없음 | [1. Azure Databricks workspace 만들기](#1-azure-databricks-workspace-만들기) | 새 workspace와 접속 정보 준비 |
| Workspace에서 Anthropic Claude를 이미 호출할 수 있음 | [2. 기존 workspace에 Claude Code 연결하기](#2-기존-workspace에-claude-code-연결하기) | Claude Code가 Databricks의 네이티브 Anthropic API를 직접 사용 |

**두 번째 가이드는 첫 번째 가이드를 실행하지 않아도 됩니다.** 회사나 다른 팀이 만든
workspace, 이미 배포된 serving endpoint, Databricks-hosted Claude 모델을 그대로 사용할
수 있습니다.

Microsoft Agent Framework(MAF) 샘플은 workspace와 모델 연결을 확인하는 별도 실습으로
유지합니다. 다만 workspace 생성이나 Claude Code 연결의 필수 단계로 묶지는 않습니다.

> 최종 검증: 2026-07-13. 모델과 리전 가용성, 쿼터, Preview 기능은 변경될 수 있으므로
> 운영 적용 전 공식 문서를 다시 확인하세요.

## 1. Azure Databricks workspace 만들기

새 Azure Databricks workspace가 필요한 사용자를 위한 경로입니다.

> Workspace 생성과 Claude 모델 가용성은 별개입니다. 사용할 Claude 모델이 지원되는
> 리전을 먼저 선택하세요. 이 리포의 스크립트는 custom model serving endpoint를
> 배포하지 않고, 해당 workspace에서 호출 가능한 Databricks-hosted 모델을 검증합니다.

### 빠른 시작

macOS, Linux 또는 WSL:

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else "Python 3.10+ required")'

az extension add --name databricks --upgrade
az login
az account set --subscription "<name-or-id>"

RG=my-rg LOCATION=koreacentral WORKSPACE=my-workspace \
  scripts/setup_databricks_claude.sh
```

스크립트는 다음 작업을 수행합니다.

1. 리소스 그룹과 Azure Databricks workspace 생성 또는 재사용
2. 빠른 로컬 검증용 PAT 생성과 `.env` 작성
3. 설정한 Claude 모델의 OpenAI 호환 API와 네이티브 Anthropic API smoke test

MAF 샘플은 기본적으로 실행하지 않습니다. 필요한 경우에만 명시적으로 실행합니다.

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
RUN_AGENT=1 scripts/setup_databricks_claude.sh
```

Windows에서 workspace만 생성하거나 각 단계를 직접 제어하려면
[Azure Databricks workspace 생성 가이드](docs/azure-databricks-setup.md)를 따르세요.

## 2. 기존 workspace에 Claude Code 연결하기

다음 세 값이 준비되어 있으면 이 경로부터 시작합니다.

| 값 | 예 |
| --- | --- |
| Workspace URL | `https://adb-<workspace-id>.<number>.azuredatabricks.net` |
| 호출 가능한 Claude 모델 ID | `databricks-claude-opus-4-8` |
| 모델 호출 credential | 기본 시작은 PAT, 선택적으로 OAuth U2M, 운영 자동화는 OAuth M2M |

- 사전 구성된 Databricks-hosted pay-per-token 모델은 workspace 접근 권한과 유효한
  token이 필요하며, Foundation Model Unity Catalog 권한 기능을 사용하면 대상
  `system.ai` 모델의 `EXECUTE`도 필요합니다.
- 직접 만든 custom/external serving endpoint를 사용한다면 endpoint ACL의 `CAN QUERY`도
  필요합니다.

Claude Code는 Databricks의 네이티브 Anthropic Messages API에 직접 연결됩니다.

```text
Claude Code
  └─ https://<workspace-host>/serving-endpoints/anthropic/v1/messages
```

### 한 파일 설정

macOS/Linux:

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks
mkdir -p .claude
```

Windows PowerShell:

```powershell
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
Set-Location claude-on-azure-databricks
New-Item -ItemType Directory -Force -Path .claude | Out-Null
```

`.claude/settings.local.json`에 workspace URL, PAT, 모델 ID를 입력합니다.
Claude Code가 이 파일을 직접 읽어 `/model` 선택기의 Opus/Sonnet/Haiku mapping까지
구성하므로 별도 자동 스크립트는 필요하지 않습니다.

가장 쉬운 시작 경로는 PAT입니다. 정적 PAT 저장을 피하려면
[OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)을
선택할 수 있습니다. 운영 자동화는
[OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)을
사용하세요.

전체 JSON은
[Claude Code에서 Azure Databricks Claude 사용하기](docs/claude-code-databricks.md)를
따르세요.

### 연결 확인

```bash
claude --model databricks-claude-opus-4-8 \
  -p "Reply with exactly: DIRECT OK" \
  --output-format json
```

대화형으로 실행한 뒤 `/model`에서 검증된 Databricks 모델을 선택할 수 있습니다.

```bash
claude
```

## 추가 가이드

- [Microsoft Agent Framework 샘플](docs/agent-framework.md): OpenAI 호환
  Chat Completions 경로를 확인하는 별도 실습

## 보안과 비용

- `.env`, PAT, 생성된 token helper 파일을 커밋하지 마세요.
- PAT는 가장 쉬운 로컬 시작 방법입니다. 보안 요구가 높으면 OAuth U2M을 선택하고, 운영
  자동화는 서비스 주체 OAuth M2M을 사용하세요.
- Workspace와 pay-per-token 모델 사용에는 비용이 발생합니다. 실습용 리소스는 사용 후
  [workspace 생성 가이드의 정리 절차](docs/azure-databricks-setup.md#정리)로 삭제하세요.

## 공식 문서

- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Azure Databricks OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
