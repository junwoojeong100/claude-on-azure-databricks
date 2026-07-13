# Databricks-hosted Claude vs Claude in Microsoft Foundry

> 최종 검증: 2026-07-13. 모델 가용성, 쿼터, 가격, Preview 상태는 자주 바뀌므로
> 배포 전 [공식 문서](#공식-참고-문서)를 다시 확인하세요.
>
> 이 문서는 운영 선택을 위한 심화 비교입니다. 시작 경로는 [README](../README.md),
> 새 workspace 생성은 [Azure Databricks workspace 생성 가이드](azure-databricks-setup.md),
> Claude Code 연결은 [직접 연결 가이드](claude-code-databricks.md)를 참고하세요.

## TL;DR

- **Azure Databricks**는 사전 구성된 pay-per-token endpoint에서 Claude를 호출하고
  endpoint용 AI Gateway와 새 Unity AI Gateway (Beta), Unity Catalog, 시스템 테이블로
  관리합니다. OpenAI 호환 Chat Completions와 provider-native Anthropic Messages API를
  모두 제공합니다.
- **Microsoft Foundry**의 Claude는 `Hosted on Azure`와
  `Hosted on Anthropic infrastructure` 중 가용한 방식을 선택하고, Anthropic Messages
  API로 호출합니다. Anthropic이 판매자이자 모델 운영자이며, Microsoft가 Azure
  Marketplace CCU 사용량을 Azure 청구서에 반영합니다.
- Foundry Claude 배포에는 **Azure AI Content Safety 필터가 기본으로 붙지 않습니다.**
  조직 정책에 필요하면 별도 안전 계층을 구성해야 합니다.
- 선택 기준은 단순한 API 차이보다 **데이터가 이미 어디에 있는지**, **어느 control
  plane에서 권한·네트워크·비용을 관리할지**, **어느 hosting option의 데이터 처리
  조건이 필요한지**입니다.

## 1. Control plane과 운영 책임

| 항목 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| 모델 카탈로그 | Databricks Foundation Model APIs | Foundry model catalog |
| Claude 운영 방식 | Databricks-hosted pay-per-token endpoint | Hosted on Azure 또는 Hosted on Anthropic infrastructure |
| 권한 | Workspace endpoint ACL + Unity Catalog | Azure RBAC + Foundry resource/project 권한 |
| 정책 적용 | endpoint용 AI Gateway + Unity AI Gateway (Beta) | Azure resource/network 정책 + 애플리케이션 안전 계층 |
| 지원 경로 | Azure Databricks 지원 | Microsoft Support |

Foundry에서도 Claude는 Microsoft 모델이 아닙니다. 두 hosting option 모두 Anthropic이
판매자와 운영자이며 Anthropic 약관이 적용됩니다. Microsoft는 Foundry 경험, Azure
인프라 일부, Marketplace 구매·청구, 지원 접점을 제공합니다.

## 2. 인증과 최소 권한

| 작업 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| 개발용 인증 | PAT(legacy) 또는 사용자 OAuth | API key 또는 Microsoft Entra ID |
| 운영용 인증 | 서비스 주체 OAuth M2M 권장 | Managed Identity/서비스 주체 + Entra ID 권장 |
| 추론 권한 | endpoint `CAN QUERY`; Foundation Model UC 권한 사용 시 대상 `system.ai` 모델 `EXECUTE` | Foundry resource 범위의 `Foundry User`(구 `Azure AI User`) 권장. 직접 모델 호출은 `Cognitive Services User`도 가능 |
| 배포 권한 | 모델/endpoint 유형별 관리 권한 | Resource group `Contributor`/`Owner` + Marketplace 구독 권한 |
| 역할 할당 | endpoint `CAN MANAGE` 또는 workspace admin | `Owner` 또는 `User Access Administrator` 등 역할 할당 권한 |

Foundry에서 `Owner`나 `Contributor`만 있다고 Entra 기반 추론 권한이 생기지는 않습니다.
호출 주체에는 별도로 `Foundry User`(구 `Azure AI User`)를 부여하는 것이 권장됩니다.
`Cognitive Services User`는 `Foundry User`의 이전 이름이나 별칭이 아니라 별도의
Azure AI Services 역할이지만, Foundry resource 범위에서 Claude 모델 호출
권한도 제공합니다. Foundry project나 agent 작업에는 Foundry-native 역할을 사용하세요.
반대로 배포 권한과 추론 권한은 같은 역할이 아닙니다. 모델 배포의
`Contributor`/`Owner`는 resource group 범위이고, Marketplace offer 구독 권한은
subscription 범위이므로 scope도 구분하세요.

## 3. API와 네트워크 경로

| 항목 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| OpenAI 호환 API | `/serving-endpoints/chat/completions` | Claude의 주 호출 경로가 아님 |
| Anthropic API | `/serving-endpoints/anthropic/v1/messages` | `https://<resource>.services.ai.azure.com/anthropic/v1/messages` |
| 권장 SDK | OpenAI SDK 또는 Anthropic 호환 클라이언트 | Anthropic SDK 또는 REST |
| 모델 선택 | 사전 구성 endpoint 이름 | 배포 시 정한 deployment 이름 |
| 네트워크 제어 | Databricks workspace와 serverless/model-serving 네트워크 정책 | Foundry resource의 네트워크 설정과 선택한 Claude hosting option |

Foundry의 `Hosted on Anthropic infrastructure`를 선택하면 Microsoft Foundry endpoint를
사용하더라도 실제 프롬프트·출력 처리는 Anthropic 인프라에서 이루어질 수 있습니다.
Private Endpoint나 지역 제한 요구가 있다면 모델 이름만 보지 말고 hosting option과
해당 배포 유형의 데이터 처리 범위를 함께 검토하세요.

두 hosting option 모두 Messages와 token counting API를 제공하지만, 현재 `/files`와
`/skills` API는 Hosted on Anthropic infrastructure에서만 제공됩니다. 애플리케이션이
Messages 외 API를 사용한다면 hosting option별 API 표를 확인하세요.

## 4. 관측성과 안전 제어

| 항목 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| 토큰·요청 메트릭 | endpoint gateway의 `system.serving.*` 또는 Unity AI Gateway의 `system.ai_gateway.usage` | Foundry 모델 Monitoring 탭의 모델별 token/request |
| 요청·응답 payload | AI Gateway-enabled Inference Tables | 지원되는 진단 로그 또는 애플리케이션 telemetry를 별도 구성 |
| 비용 원장 | `system.billing.usage`와 Databricks 비용 대시보드 | Azure Cost Management의 CCU + Foundry portal 모델별 상세 |
| 애플리케이션 추적 | Databricks jobs/notebooks 또는 외부 OTEL | Application Insights/OpenTelemetry 선택 구성 |
| 안전 필터 | endpoint guardrail, Unity service policy 또는 애플리케이션 계층 | Azure AI Content Safety가 배포 시 자동 적용되지 않음 |

Foundry Claude에는 Anthropic의 자체 안전 시스템과 safeguards가 적용되지만, 이는
Azure AI Content Safety 필터가 자동 연결된다는 뜻이 아닙니다. 차단 기준, 감사 로그,
PII 처리 같은 조직 요구사항은 별도 inference-time 정책으로 설계하세요.

## 5. 과금과 비용 가시성

| 항목 | Azure Databricks | Microsoft Foundry Claude |
| --- | --- | --- |
| 추론 과금 | pay-per-token 사용량을 Databricks DBU로 청구 | token 사용량을 Claude Consumption Unit(CCU)로 변환 |
| 청구 경로 | Azure Databricks 사용량으로 Azure 청구서에 반영 | Azure Marketplace CCU로 Microsoft Azure 청구서에 반영 |
| 약정 | Azure Databricks 계약/약정 조건 | CCU는 MACC eligible, private offer 할인 가능 |
| Azure Cost Management | Databricks resource/SKU 수준 집계 | Claude는 단일 CCU line으로 집계 |
| 모델별 상세 | Databricks usage/billing system tables | Foundry portal Monitoring 탭 |
| 선불 용량 | endpoint 유형과 Databricks 계약에 따라 다름 | CCU는 pay-as-you-go이며 prepaid CCU credit이 아님 |

CCU는 가격 자체가 아니라 **청구 단위**입니다. 모델별 input/output token 단가와
할인을 적용한 금액이 CCU로 변환됩니다. Azure Cost Management에는 Claude 사용량이
단일 CCU meter로 보이므로, 모델별 token과 request 분석은 Foundry portal을 사용해야
합니다.

현재 새 Claude 배포는 CCU로 청구되지만, CCU 전환 전에 만든 기존 배포는 기존
per-model plan을 유지할 수 있습니다. 정확한 비교 견적은 두 플랫폼의 현재 가격표와
계약 할인을 함께 적용해 계산하세요.

## 6. 모델, hosting option, 배포 유형

### Azure Databricks

- Claude는 사전 구성된 pay-per-token Foundation Model API endpoint로 제공됩니다.
- 실험과 일반 사용은 pay-per-token, 보장된 처리량이 필요한 지원 모델 아키텍처는
  provisioned throughput을 검토합니다.
- 모델·리전 가용성과 기본 ITPM/OTPM/QPH 제한은 Databricks 문서에서 확인합니다.

### Microsoft Foundry

- 모델에 따라 `Hosted on Azure`, `Hosted on Anthropic infrastructure`, 또는 둘 다
  제공됩니다. 둘 다 있으면 portal의 기본 배포는 Hosted on Azure입니다.
- 검증 시점 기준 Claude는 **Global Standard**를 사용하며, Azure-hosted
  `claude-opus-4-8`과 `claude-sonnet-5`는 **Data Zone Standard (US)**도 지원합니다.
- Hosted on Anthropic infrastructure는 Global Standard만 지원합니다.
- Claude의 현재 배포 선택지를 일반 Foundry 모델의 PTU/Reservation 기능과 동일하게
  취급하면 안 됩니다. Claude 공식 가용성 표에 표시된 deployment type만 사용하세요.
- Global Standard Claude 배포를 만들 수 있는 Foundry project/resource 위치는
  모델과 버전별로 다릅니다. East US 2와 Sweden Central로 고정하지 말고 배포 직전
  공식 `Region availability by deployment type` 표를 확인하세요.

모델 목록과 lifecycle 상태는 두 hosting option 사이에서도 다를 수 있습니다. 최신
모델뿐 아니라 필요한 API 기능이 선택한 option에서 지원되는지도 확인하세요.

## 7. 쿼터와 rate limit

| 항목 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| 기본 범위 | workspace tier, 모델, endpoint 유형에 따라 적용 | subscription에서 모델·버전·deployment type별 공유 |
| 지표 | ITPM, OTPM, QPH | RPM, uncached ITPM |
| 초과 응답 | 일반적으로 429 | 일반적으로 429 |
| 증설 | endpoint 유형 변경 또는 Databricks 지원 경로 | Foundry quota increase request |

Databricks의 현재 Claude pay-per-token 표에는 기본 ITPM/OTPM/QPH가 게시되어 있지만
플랫폼 tier와 모델에 따라 달라질 수 있습니다. `403 ... rate limit of 0`은 일반 429와
다르며, 메시지만으로 account entitlement 문제라고 단정하지 말고
[환경 설정 가이드의 진단 순서](azure-databricks-setup.md#자주-발생하는-문제)를 따르세요.

Foundry 쿼터는 같은 subscription의 resource와 region이 공유할 수 있습니다. 검증 시점
기준 Free Trial, Student, credit-based, Cloud Solution Provider(CSP), 그리고
South Korea의 Enterprise Account는 Claude를 지원하지 않으므로 구독 유형도 함께
확인하세요. 또한 `claude-fable-5`의 pay-as-you-go 기본 쿼터는 현재 RPM 0, ITPM 0이며,
Enterprise/MCA-E 표에서만 양의 기본 쿼터가 제공됩니다.

## 8. 데이터 처리와 컴플라이언스

### Azure Databricks

Foundation Model APIs는 Databricks Designated Service이며 Databricks Geo를 기준으로
customer content를 처리합니다. workspace region만으로 모든 처리 위치를 단정하지 말고
해당 모델의 region availability와 designated services/cross-Geo 설정을 확인하세요.

Claude Fable 5는 예외적으로 프롬프트와 응답을 trust and safety 목적으로 30일
보존합니다. 자동 안전 시스템이 처리하고 일부 경우 사람 검토 대상이 될 수 있으며,
안전 조사나 법적 요구가 있으면 30일을 넘어 보존될 수 있습니다. Anthropic은 이 보존
목적의 limited subprocessor이므로
[공식 모델 정책](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models#claude-fable-5)을
별도로 검토하세요.

### Microsoft Foundry

| 항목 | Hosted on Azure | Hosted on Anthropic infrastructure |
| --- | --- | --- |
| 처리 위치 | Azure 인프라에서 ingress, API, GPU inference 처리 | Anthropic 인프라에서 처리 |
| 저장 위치 | 선택한 Azure geography에 data at rest 저장 | Anthropic 약관과 처리 조건 적용 |
| 배포 범위 | Global Standard 또는 지원 모델의 Data Zone Standard | Global Standard |
| Azure 밖 처리 | 선택한 배포 범위에 따름 | Azure 및 선택 region 밖에서 처리될 수 있음 |

두 option 모두 Anthropic이 독립 data processor로 동작하고 Anthropic 상업 약관과
Data Processing Addendum가 적용됩니다. Hosted on Azure도 automatic safeguard가
예외적인 안전 위반 조사를 위해 Anthropic Trust & Safety review로 이어질 수 있으므로,
규제 워크로드는 조직의 법무·보안 검토를 거치세요.

## 9. 애플리케이션과 Agent 통합

| 항목 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| 이 리포의 Python 샘플 | `OpenAIChatCompletionClient` + OpenAI 호환 endpoint | 직접 전환 시 client/auth/base URL 변경 필요 |
| Claude Code | 네이티브 Anthropic endpoint로 custom base URL 연결 또는 `ucode` | 공식 Foundry integration(`CLAUDE_CODE_USE_FOUNDRY=1`)과 API key/Entra ID 지원 |
| Claude API 기능 | Databricks가 노출한 Anthropic 호환 범위 | 선택한 Foundry hosting option이 지원하는 Claude API 범위 |
| Agent 서비스 | 직접 구성 또는 Databricks agent 기능 | Microsoft Agent Framework 또는 Agent Service가 지원하는 Claude deployment 사용; 외부 gateway 모델은 BYOM |

Foundry Claude 자체 호출은 Anthropic SDK/REST를 사용합니다. Microsoft Agent
Framework가 Claude agent를 지원하며, Foundry Agent Service도 현재 일부 Claude 모델을
직접 지원합니다. 모델·리전·hosted tool별 지원 범위는 Agent Service limits 표에서
확인하세요.

Agent Service의 Bring Your Own Model(BYOM)은 Azure API Management나 외부 gateway
뒤의 모델을 연결할 때 사용합니다. BYOM 모델은 OpenAI-compatible Chat Completions
API를 구현해야 하므로, Foundry Claude의 네이티브 Anthropic Messages endpoint를 BYOM
연결로 직접 등록할 수는 없습니다. 이 경로가 필요하면 gateway에서 protocol 변환을
구성해야 합니다. hosted tools와 evaluation 지원도 deployment별로 확인하세요.

마이그레이션 시에는 client만 바꾸지 말고 다음 항목을 함께 옮겨야 합니다.

1. endpoint와 deployment/model 이름
2. PAT/OAuth와 Entra ID/API key
3. endpoint ACL과 Azure RBAC
4. private networking과 egress 정책
5. safety/guardrail 정책
6. token·비용·payload 관측 파이프라인

## 10. 관리자 역할 비교

| 작업 | Azure Databricks | Microsoft Foundry |
| --- | --- | --- |
| 모델 호출 권한 부여 | endpoint `CAN MANAGE` 보유자 또는 workspace admin | Azure role assignment 권한 보유자 |
| 모델 호출 | endpoint `CAN QUERY`; Foundation Model UC 권한 사용 시 모델 `EXECUTE` | `Foundry User`(구 `Azure AI User`) 권장. 직접 모델 호출은 `Cognitive Services User`도 가능 |
| endpoint/AI Gateway 설정 | endpoint `CAN MANAGE` | Foundry resource/project 관리 역할 |
| Marketplace 구독·배포 | 해당 없음 | Marketplace 구매 권한 + resource group `Contributor`/`Owner` |
| 시스템 사용량 조회 | endpoint `system.serving.*`은 전용 문서상 account admin이며 일반 system-table grant로 위임 가능. Unity `system.ai_gateway.usage`는 현재 account admin만 가능 | Foundry Monitoring, Cost Management, Monitor별 RBAC |
| 데이터 거버넌스 | Unity Catalog + account/workspace 역할 | Azure RBAC + resource/project 권한 |

Databricks는 Account, Workspace, Unity Catalog 역할이 분리됩니다. Foundry는 Azure
RBAC가 중심이지만, 배포 권한, Marketplace 구매 권한, inference data-plane 권한,
Cost Management 권한이 각각 다르므로 `Contributor` 하나로 모든 작업이 되지는
않습니다.

## 11. 모니터링 리소스와 추가 비용

모델 token 비용과 별도로 관측 데이터를 저장·조회하는 리소스에도 비용이 생길 수
있습니다. 아래 표는 가격을 고정값으로 가정하지 않고 비용 발생 지점만 정리합니다.

### 11.1 Azure Databricks

| 목적 | 필요한 기능/리소스 | 비용 지점 |
| --- | --- | --- |
| token/request 집계 | endpoint **Enable usage tracking** + `system.serving.*` | usage tracking 기능 요금 + 조회 SQL/compute |
| Unity model service 통합 관측 | `system.ai_gateway.usage` + 빌트인 dashboard | Beta 중 gateway 기능 자체는 무료지만 dashboard query용 SQL/compute 비용 |
| endpoint/model 메타데이터 | `system.serving.served_entities` | 조회에 사용하는 SQL/compute 비용 |
| payload 감사 | Inference Tables + Unity Catalog + serverless compute | payload logging 기능 요금 + Delta storage와 조회/처리 compute |
| 비용 귀속 | `system.billing.usage`, custom tags, 비용 dashboard | dashboard를 실행하는 SQL Warehouse/compute |
| 알림·이상 탐지 | SQL alert, job, Lakehouse Monitoring 또는 외부 도구 | 실행 compute와 외부 서비스 비용 |

Serving endpoint용 AI Gateway는 활성화한 기능별로 과금됩니다. payload logging과 usage
tracking은 유료이고, query permission, rate limit, fallback, traffic splitting은
무료입니다. 별도 제품인 Unity AI Gateway Beta 기능 자체는 Beta 기간 중 과금되지
않지만 dashboard query용 SQL/compute 같은 연관 리소스 비용은 발생할 수 있습니다.

Inference Tables를 활성화하려면 endpoint `CAN MANAGE`, serverless compute, Unity
Catalog, 대상 catalog의 `USE CATALOG`, schema의 `USE SCHEMA`와 `CREATE TABLE`이
필요합니다. 테이블 스키마·이름을 임의로 바꾸거나 삭제하면 logging이 중단될 수
있습니다.

`system.serving.endpoint_usage`에는 `endpoint_name`이 없으므로
`served_entity_id`로 `system.serving.served_entities`를 조인해야 합니다. 실제 쿼리는
[Databricks system tables reference](https://learn.microsoft.com/azure/databricks/admin/system-tables/)의
현재 스키마를 기준으로 작성하세요.
다른 사용자에게 조회를 위임하려면 account admin과 metastore admin을 모두 보유한
관리자가 `system` catalog와 대상 schema의 `USE`·`SELECT` 권한을 부여해야 합니다.
이 일반 위임 절차는 `system.serving.*`에 적용할 수 있지만, 현재 Unity AI Gateway Beta
문서는 `system.ai_gateway.usage` 조회를 account admin으로 제한합니다.

### 11.2 Microsoft Foundry

| 목적 | 필요한 기능/리소스 | 비용 지점 |
| --- | --- | --- |
| 모델별 token/request | Foundry portal Monitoring | 별도 관측 저장소 없이 portal에서 확인 |
| 청구 확인 | Azure Cost Management | Claude는 단일 CCU line으로 집계 |
| 애플리케이션 trace | Application Insights/OpenTelemetry | telemetry ingestion·retention |
| 장기 로그 분석 | 지원되는 Diagnostic Settings + Log Analytics/Storage/Event Hubs | 수집량, 보존 기간, sink 비용 |
| 알림 | Azure Monitor alert + Action Group | 규칙 유형과 알림 채널별 비용 |
| 추가 안전 필터 | Azure AI Content Safety 또는 자체 policy layer | 선택한 서비스의 사용량 |

Diagnostic Settings의 category와 payload 제공 범위는 Foundry resource와 모델에 따라
다를 수 있습니다. 요청/응답 원문이 항상 자동 수집된다고 가정하지 말고 배포 후
지원 category를 확인하세요.

### 11.3 비용 통제 체크리스트

- Databricks SQL Warehouse는 auto-stop을 짧게 설정하고 dashboard refresh 주기를
  필요한 수준으로 제한합니다.
- Inference Tables에는 민감정보 보존 정책과 삭제 주기를 적용합니다.
- Foundry에서는 CCU 재무 원장과 portal의 모델별 token 상세를 함께 봅니다.
- Log Analytics와 Application Insights는 필요한 category만 수집하고 sampling과
  retention으로 비용을 제한합니다.
- 두 플랫폼 모두 budget/alert만 믿지 말고 endpoint 또는 사용자별 rate limit도
  함께 설정합니다.

## 언제 어느 쪽이 맞나

**Azure Databricks가 적합한 경우**

- Lakehouse 데이터와 inference 결과를 같은 Unity Catalog 경계에서 관리해야 할 때
- 데이터·ML 운영팀이 Databricks 권한과 AI Gateway를 표준으로 사용할 때
- OpenAI 호환 API와 Anthropic Messages API를 같은 workspace에서 함께 사용해야 할 때

**Microsoft Foundry가 적합한 경우**

- Entra ID, Azure RBAC, Marketplace, Cost Management를 AI 플랫폼 표준으로 사용할 때
- Hosted on Azure 또는 Data Zone Standard의 데이터 처리 조건이 필요할 때
- Claude와 다른 Foundry catalog 모델을 같은 Azure resource 운영 체계에서 관리할 때

## 공식 참고 문서

- [Claude models in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models)
- [Compare hosting options for Claude models](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-hosting-comparison)
- [Claude Consumption Units billing](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing)
- [Data, privacy, and security for Claude models](https://learn.microsoft.com/azure/foundry/responsible-ai/claude-models/data-privacy)
- [Deploy and use Claude models](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/use-foundry-models-claude)
- [Role-based access control for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)
- [Region availability by deployment type](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-from-partners#region-availability-by-deployment-type)
- [Configure keyless authentication for Foundry Models](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-entra-id)
- [Configure Claude Code for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-claude-code)
- [Claude Code on Microsoft Foundry](https://code.claude.com/docs/en/microsoft-foundry)
- [Foundry Agent Service limits and supported models](https://learn.microsoft.com/azure/foundry/agents/concepts/limits-quotas-regions)
- [Bring your own model to Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)
- [Databricks Foundation Model APIs](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Databricks Foundation Model API limits](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/limits)
- [AI governance with Unity AI Gateway](https://learn.microsoft.com/azure/databricks/ai-gateway/)
- [AI Gateway for serving endpoints](https://learn.microsoft.com/azure/databricks/ai-gateway/overview-serving-endpoints)
- [Model usage for Unity AI Gateway](https://learn.microsoft.com/azure/databricks/ai-gateway/usage-tracking)
- [Configure AI Gateway on model serving endpoints](https://learn.microsoft.com/azure/databricks/ai-gateway/configure-ai-gateway-endpoints)
- [Monitor served models with inference tables](https://learn.microsoft.com/azure/databricks/ai-gateway/inference-tables-serving-endpoints)
