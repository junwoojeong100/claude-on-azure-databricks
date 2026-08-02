# Azure Databricks workspace 만들기

이 가이드의 목표는 **새 Azure Databricks workspace를 만드는 것**입니다.

이미 workspace가 있고 그곳에서 Anthropic Claude 모델을 호출할 수 있다면 이 가이드를
건너뛰고 [Claude Code 연결 가이드](claude-code-databricks.md)부터 시작하세요.

> Workspace 생성과 Claude 모델 가용성은 별개입니다. 사용할 Claude 모델이 지원되는
> 리전을 먼저 선택하세요. 이 리포의 스크립트는 custom model serving endpoint를
> 배포하지 않고, workspace에서 호출 가능한 Databricks-hosted 모델을 검증합니다.

Azure Databricks는 serverless workspace와 Azure 구독의 리소스 그룹에 배포되는
classic (hybrid) workspace를 제공합니다. 이 리포의 스크립트와 Azure CLI 예시는 Premium
classic workspace를 만듭니다. 조직이 serverless workspace를 제공한다면 새 리소스를
만들지 말고 [Claude Code 연결 가이드](claude-code-databricks.md)부터 시작하세요.

## 준비 사항

| 항목 | 요구사항 |
| --- | --- |
| Azure 구독과 권한 | Free Trial이 아닌 구독, Contributor 또는 동등한 리소스 생성 권한 |
| Azure CLI | 로그인 가능, Databricks 확장 설치 가능 |
| 리전 | 사용할 Databricks-hosted Claude 모델이 지원되는 Azure 리전 |
| 로컬 도구 | 자동 스크립트 사용 시 Git, `curl`, Python 3.10 이상 |

모델 ID와 리전 가용성은 다음 공식 문서에서 확인합니다.

- [지원 모델](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [리전별 Foundation Model 가용성](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/foundation-model-overview)

이 가이드와 스크립트의 기본 예시는 Opus 5, Sonnet 5, Haiku 4.5를 제공하는
`eastus2`를 사용합니다. `koreacentral`에서는 Opus 5, Sonnet 4.6, Haiku 4.5가
cross-Geo 대상으로 표시되지만 Sonnet 5는 현재 리전 표에 없습니다. 한국 리전을
선택한다면 Sonnet mapping을 Sonnet 4.6으로 바꾸고, 계정 관리자가
[cross-Geo 처리 설정](https://learn.microsoft.com/azure/databricks/resources/databricks-geos#cross-geo-processing)과
조직의 데이터 레지던시 요구사항을 먼저 확인해야 합니다.

이 스크립트의 smoke test 모델과 Claude Code의 `/model` picker 구성은 서로 독립적입니다.
Smoke test는 모델 하나로 연결을 확인하고, 성공하면
[Claude Code 연결 가이드](claude-code-databricks.md#4-다중-모델-영구-설정)의 기본
다중 모델 구성을 적용합니다. Workspace에서 호출할 수 없는 모델은 설정에서 제거하세요.

## 1. 자동 생성

자동 스크립트는 workspace를 만든 뒤 빠른 로컬 검증용 PAT와 `.env`까지 준비합니다.

### 로컬 환경 준비

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else "Python 3.10+ required")'
```

Windows PowerShell:

```powershell
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
Set-Location claude-on-azure-databricks

py -3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else "Python 3.10+ required")'
```

### Azure 로그인

```bash
az extension add --name databricks --upgrade
az login
az account set --subscription "<name-or-id>"
```

### Workspace 생성

macOS, Linux, WSL:

```bash
RG=my-rg LOCATION=eastus2 WORKSPACE=my-workspace \
  scripts/setup_databricks_claude.sh
```

Windows PowerShell:

```powershell
.\scripts\Setup-DatabricksClaude.ps1 `
  -ResourceGroup my-rg `
  -Location eastus2 `
  -Workspace my-workspace
```

환경변수를 생략하면 다음 기본값을 사용합니다.
PowerShell에서는 `-ResourceGroup`, `-Location`, `-Workspace` 같은 parameter로 같은
값을 직접 지정할 수 있습니다.

| 변수 | 기본값 | 역할 |
| --- | --- | --- |
| `RG` | `rg-databricks-claude` | 리소스 그룹 |
| `LOCATION` | `eastus2` | Azure 리전 |
| `WORKSPACE` | `ws-databricks-claude` | Databricks workspace |
| `SKU` | `premium` | Workspace SKU |
| `DATABRICKS_SERVING_ENDPOINT` | `databricks-claude-opus-5` | 검증할 기본 Claude 모델 |
| `CONFIGURE_CLAUDE_CODE` | `1` | 성공 시 Claude Code 다중 모델 설정 병합 |
| `CLAUDE_CODE_SCOPE` | `project` | `project` 또는 `user` 설정 범위 |

스크립트는 다음 작업을 수행합니다.

1. 리소스 그룹과 Premium Databricks workspace 생성 또는 재사용
2. Azure 로그인으로 로컬 검증용 PAT 생성 또는 기존 유효 PAT 재사용
3. 기존 `.env`가 있으면 백업하고 프로젝트 루트에 새 `.env` 작성
4. 설정한 Claude 모델의 OpenAI 호환 API와 네이티브 Anthropic API smoke test
5. 기존 설정을 백업하고 Claude Code 다중 모델 설정 병합

OpenAI 호환 경로만 성공하고 네이티브 Anthropic 경로가 실패하면 Claude Code 설정은
변경하지 않습니다.

정상 완료 후 프로젝트 루트의 `.env`에 다음 값이 저장됩니다.

```dotenv
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-5
DATABRICKS_TOKEN=<databricks-token>
```

Claude Code 설정은 기본적으로 현재 repository의 `.claude/settings.local.json`에
병합됩니다. 기존 파일은 변경 전에 `.bak.<timestamp>`로 백업하며 최신 백업 1개만
유지합니다. 모든 프로젝트에 적용해야 할 때만 다음처럼 user scope를 선택하세요.

```bash
CLAUDE_CODE_SCOPE=user scripts/setup_databricks_claude.sh
```

기존 프로젝트 루트 `.env`는 덮어쓰기 전에 `.env.bak.<timestamp>`로 백업됩니다.
백업에도 credential이 포함되므로 원본과 동일하게 안전하게 보관하고, 더 이상 필요하지
않으면 삭제하세요.

Claude Code 설정을 건드리지 않으려면 `CONFIGURE_CLAUDE_CODE=0`을 사용합니다.

같은 workspace에서 다시 실행하면 유효한 `.env` PAT를 재사용합니다. 새 PAT가 꼭 필요할
때만 다음 옵션을 사용하고, 새 token을 검증한 뒤 이전 token을 폐기하세요.

```bash
ROTATE_PAT=1 scripts/setup_databricks_claude.sh
```

### 최종 확인

스크립트가 완료된 뒤 새 터미널에서 repository root로 이동해 실행합니다.

```bash
cd /path/to/claude-on-azure-databricks
claude -p "Reply with exactly: WORKSPACE SETUP OK" --output-format json
```

Windows PowerShell에서는 먼저
`Set-Location C:\path\to\claude-on-azure-databricks`를 실행합니다.

`is_error`가 `false`이고 `modelUsage`에 기본 Databricks 모델 ID가 표시되어야 합니다.
대화형 `/status`에서는 Anthropic base URL이 workspace의
`/serving-endpoints/anthropic`인지 확인합니다.

## 2. Workspace만 생성: Azure CLI

PAT 생성이나 모델 검증 없이 Azure 리소스만 만들려면 Azure CLI를 직접 사용합니다.

macOS/Linux/WSL:

```bash
RG="my-rg"
LOCATION="eastus2"
WORKSPACE="my-workspace"

az extension add --name databricks --upgrade
az login
az account set --subscription "<name-or-id>"

az group create --name "$RG" --location "$LOCATION"
az databricks workspace create \
  --resource-group "$RG" \
  --name "$WORKSPACE" \
  --location "$LOCATION" \
  --sku premium

az databricks workspace show \
  --resource-group "$RG" \
  --name "$WORKSPACE" \
  --query workspaceUrl \
  --output tsv
```

Windows PowerShell:

```powershell
$ResourceGroup = 'my-rg'
$Location = 'eastus2'
$Workspace = 'my-workspace'

az extension add --name databricks --upgrade
az login
az account set --subscription '<name-or-id>'

az group create --name $ResourceGroup --location $Location
az databricks workspace create `
  --resource-group $ResourceGroup `
  --name $Workspace `
  --location $Location `
  --sku premium

az databricks workspace show `
  --resource-group $ResourceGroup `
  --name $Workspace `
  --query workspaceUrl `
  --output tsv
```

출력된 host 앞에 `https://`를 붙인 값이 `DATABRICKS_HOST`입니다.

```text
https://adb-<workspace-id>.<number>.azuredatabricks.net
```

Workspace 생성만으로 모든 Claude 모델을 호출할 수 있는 것은 아닙니다. 다음 단계에서
실제 모델 ID, 권한, 리전과 계정 용량을 확인해야 합니다.

## 3. 다음 단계 선택

### Claude Code 연결

Workspace URL, 호출 가능한 Claude 모델 ID, token을 준비한 뒤
[기존 workspace에 Claude Code 연결하기](claude-code-databricks.md)를 따릅니다.
프로젝트 루트의 `.env`가 준비되어 있다면 다음 명령으로 다중 모델 설정을 현재
프로젝트에 바로 병합할 수 있습니다.

```bash
python3 scripts/configure_claude_code.py --scope project
```

## 자주 발생하는 문제

| 증상 | 확인할 항목 |
| --- | --- |
| `az databricks` 명령이 없음 | `az extension add --name databricks --upgrade` |
| Workspace 생성 권한 오류 | 대상 구독과 리소스 그룹의 역할, 현재 `az account show` 결과 |
| PAT 메뉴가 없거나 생성 실패 | Workspace 접근 권한, PAT 허용 정책, token 최대 수명 |
| `401` | Workspace URL, token 만료, 다른 workspace의 token인지 확인 |
| `403 ... rate limit of 0` | 모델·리전, cross-Geo 정책, rate limit, custom endpoint의 `CAN QUERY`, Foundation Model UC의 `EXECUTE`, 계정 용량 |
| 모델을 찾을 수 없음 | 현재 workspace에서 실제 호출 가능한 모델 ID 확인 |
| OpenAI 경로는 성공하고 네이티브 Anthropic 경로만 실패 | Claude Code를 연결하기 전에 Claude 모델 가용성, 권한, 계정 용량을 우선 확인 |

일반 사용량 초과는 보통 `429`입니다. `403`과 `rate limit of 0` 조합은 단순 재시도보다
모델 제공 조건과 계정 설정을 먼저 확인해야 합니다.

## 정리

이 가이드로 만든 전용 리소스 그룹이 더 이상 필요하지 않을 때만 삭제합니다. 기존
workspace나 다른 리소스를 공유하는 그룹에는 실행하지 마세요.

```bash
SUBSCRIPTION_ID="<subscription-id-used-during-setup>"
RESOURCE_GROUP="<resource-group-used-during-setup>"

az group show \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$RESOURCE_GROUP" \
  --output table

az group delete \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait
```

로컬 `.env`도 더 이상 필요하지 않으면 삭제합니다.

```bash
rm -f .env
```

## 공식 문서

- [Create an Azure Databricks workspace](https://learn.microsoft.com/azure/databricks/admin/workspace/)
- [Deploy a workspace with the Azure CLI](https://learn.microsoft.com/azure/databricks/admin/workspace/azure-cli)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks cross-Geo processing](https://learn.microsoft.com/azure/databricks/resources/databricks-geos#cross-geo-processing)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
