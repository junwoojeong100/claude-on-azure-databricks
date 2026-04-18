# Databricks 호스팅 모델 vs Microsoft Foundry 모델 직접 사용 — Foundry Control Plane 관점

## TL;DR

현재 샘플처럼 **Databricks Foundation Model API**로 Claude를 호출하면 모델 거버넌스/네트워킹/관측이 **Databricks Control Plane**에 묶입니다. **Foundry Models를 직접 쓰면** Azure AI Foundry의 RBAC, Private Link, Content Safety, Cost Management, 모델 카탈로그가 **Foundry Control Plane** 한 곳에서 관리됩니다.

---

## 1. Control Plane / 거버넌스 위치

| 항목 | 현재 (Databricks 호스팅) | Foundry Models 직접 |
| --- | --- | --- |
| 모델 카탈로그 | Databricks Foundation Model API 카탈로그 | Foundry Model Catalog (Azure OpenAI + Anthropic + Meta + Mistral + xAI 등) |
| 라이프사이클 관리 | Databricks workspace 단위 | Foundry Project / Hub 단위 |
| 권한 모델 | Databricks Unity Catalog + workspace permission | **Microsoft Entra ID + Azure RBAC** |
| 정책 적용 지점 | Databricks AI Gateway | Foundry → Azure Policy + Content Safety |

> 핵심: 거버넌스 주체가 **Databricks 관리자**인지 **Azure/Foundry 플랫폼 팀**인지가 갈립니다.

## 2. 인증 (Identity)

| | 현재 | Foundry 직접 |
| --- | --- | --- |
| 인증 방식 | Databricks PAT / OAuth (workspace 토큰) | **Entra ID Managed Identity / Service Principal** (`AzureCliCredential`, `DefaultAzureCredential`) |
| 키 관리 | PAT 회전 별도 운영 | 키리스(passwordless) 가능 |
| 감사 로그 | Databricks audit logs | Entra ID Sign-in logs + Azure Activity Log |

Foundry 쪽이 Azure 표준 ID 체계에 정렬되어 **다른 Azure 리소스와 동일한 거버넌스**를 받습니다.

## 3. 네트워킹

| | 현재 | Foundry 직접 |
| --- | --- | --- |
| Private endpoint | Databricks workspace의 Private Link 통해 간접 | **Foundry/Cognitive Services Private Endpoint** 직접 |
| 데이터 경로 | Client → Databricks workspace → 모델 호스트 | Client → Foundry endpoint (직선) |
| Egress 제어 | Databricks Network Security 정책 | Azure VNet/NSG/Firewall로 Foundry 단위 제어 |

Foundry 직접이 **홉(hop)이 적고**, Azure 네트워크 정책과 일관성이 높습니다.

## 4. 관측성 (Observability)

| 항목 | 현재 | Foundry 직접 |
| --- | --- | --- |
| 메트릭 | Serving UI Metrics + `system.serving.endpoint_usage` | **Azure Monitor Metrics** + Foundry Tracing (OpenTelemetry) |
| 로그 | Databricks Inference Tables (Delta) | Diagnostic Settings → Log Analytics / Storage |
| 분산 추적 | 별도 구성 | **Agent Framework + Foundry Tracing** 네이티브 |
| 콘텐츠 안전 로그 | AI Gateway에서 별도 설정 | Content Safety가 Foundry에 기본 내장 |

Foundry는 Azure Monitor / Application Insights와 **표준 통합**, Databricks는 자체 시스템 테이블 모델입니다.

## 5. 과금 (Cost)

| | 현재 | Foundry 직접 |
| --- | --- | --- |
| 청구서 | Databricks 인보이스 (DBU 환산) | **Azure 인보이스** (다른 Azure 리소스와 합산) |
| 단위 | DBU per 1M tokens | $/1K tokens (모델별) |
| Cost Management 통합 | Azure Cost Mgmt에서 Databricks **묶음**으로 표시 | Azure Cost Mgmt에서 모델별/태그별 분해 가능 |
| 예산/알림 | Databricks Budget Policy | Azure Budget + Action Group |

여러 Azure 워크로드를 운영 중이라면 Foundry가 **단일 청구/예산 거버넌스**에 더 잘 맞습니다.

## 6. 모델 카탈로그 / 가용성

| | 현재 | Foundry 직접 |
| --- | --- | --- |
| Anthropic Claude | ✅ (Foundation Model API) | ✅ (Foundry에 Anthropic 카탈로그 추가됨) |
| Azure OpenAI (GPT-4.1, o-시리즈 등) | ❌ | ✅ |
| Meta Llama / Mistral / xAI / DeepSeek | ✅ 일부 | ✅ 광범위 |
| 자체 fine-tuned 모델 | Databricks MLflow에서 배포 | Foundry Custom Model 배포 |
| Reasoning/도구 호출 등 신규 기능 | Databricks 지원 시점 | Foundry 우선 지원 경향 |

## 7. 쿼터 / 용량

- **현재**: Databricks 워크스페이스 단위 throughput 제한 (Pay-per-token 또는 Provisioned Throughput).
- **Foundry**: 구독/리전 단위 TPM/RPM 쿼터, **PTU (Provisioned Throughput Units)** 또는 Pay-as-you-go. Reservation 구매 가능.

엔터프라이즈 SLA·예약 가격이 필요하면 Foundry PTU 모델이 일반적으로 더 풍부한 선택지를 제공합니다.

## 8. 데이터 거버넌스 / 컴플라이언스

| | 현재 | Foundry 직접 |
| --- | --- | --- |
| 학습 데이터 사용 안 함 보장 | Databricks 정책 | Foundry/Azure OpenAI 표준 정책 |
| 데이터 거주지(region pinning) | Databricks workspace region | Foundry endpoint region (세부 선택 가능) |
| 규정 준수 인증 | Databricks 인증 셋 | Azure 인증 셋 (FedRAMP, HIPAA, ISO 등 광범위) |
| Customer-managed keys | Databricks managed | Azure Key Vault 통합 |

## 9. Agent Framework 통합 측면

| | 현재 | Foundry 직접 |
| --- | --- | --- |
| 클라이언트 | `OpenAIChatCompletionClient` + httpx hook (호환 어댑터) | **`FoundryChatClient` / `FoundryAgent`** (1급 시민) |
| Hosted tools (code interpreter, file search, MCP) | 직접 구현 | **Foundry Agent Service에서 호스팅 제공** |
| Thread/Session 관리 | 클라이언트가 직접 | Foundry 서버측 관리 옵션 |
| Evaluation / Guardrails | 별도 구축 | Foundry Evaluations + Content Safety |

샘플 코드의 `/invocations` 리라이트 같은 우회가 필요 없고, Microsoft가 정식 권장 경로입니다.

---

## 10. 모니터링/관측을 위해 추가로 프로비저닝해야 하는 리소스와 비용

위의 "관측성" 섹션은 **어떤 도구로 보는가**를 다뤘다면, 여기서는 **그 도구를 쓰기 위해 별도로 활성화/생성해야 하는 리소스**와 그에 따른 **추가 비용**을 정리합니다. 모델 호출 비용(토큰 과금)은 양쪽 모두 별도이며 여기에는 포함하지 않습니다.

### 10.1 현재 (Databricks Foundation Model API)

| 용도 | 추가로 필요한 리소스 | 활성화 위치 | 비용 모델 | 실무 체감 비용 |
| --- | --- | --- | --- | --- |
| 엔드포인트 메트릭 (UI 차트) | 없음 — 기본 제공 | Serving → 엔드포인트 → Metrics 탭 | **무료** | 0 |
| Inference Tables (요청/응답 + 토큰 Delta 저장) | **Unity Catalog 스토리지 (ADLS Gen2)** | 엔드포인트 → AI Gateway → Inference tables 활성화 | ADLS 저장 용량 + 트랜잭션 | 보통 GB당 $0.02/월 수준, 호출량 비례 |
| 시스템 테이블 조회 (`system.serving.endpoint_usage` 등) | **SQL Warehouse** (Serverless 권장) 또는 **All-Purpose Cluster** + `system.serving` 스키마 활성화 (account admin) | SQL → Warehouses | DBU/시간 (Serverless SQL XS ≈ $0.7~/시간 + Azure 컴퓨트) | **쿼리할 때만 과금**되지만 자동 stop이 없으면 누적 ↑ |
| 비용 대시보드 (사용자별/엔드포인트별) | SQL Warehouse + Databricks SQL 대시보드 | SQL → Dashboards | 위와 동일 + 스케줄 새로고침 시 재기동 | 새로고침 빈도가 곧 비용 |
| 외부 모니터링 도구 연계 (Datadog 등) | 외부 도구 라이선스 + Inference Tables 또는 system 테이블에 ETL | 외부 SaaS | 외부 도구 비용 + 데이터 전송 | 도구별 상이 |
| 알림/이상 탐지 | Databricks **Lakehouse Monitoring** 또는 Job + Notebook 스케줄 | Quality → Monitors | DBU (Serverless Job) | 모니터당 수십 분/일 → 월 단위 적은 비용 |

> **저비용 출발점**: 엔드포인트 자체의 Metrics 탭 + Inference Tables(Storage만 과금)만 활성화하면 SQL Warehouse 없이도 기본 운영이 가능합니다. 정량 분석/대시보드가 필요해진 시점에 SQL Warehouse를 추가하세요.

### 10.2 Foundry Models 직접

| 용도 | 추가로 필요한 리소스 | 활성화 위치 | 비용 모델 | 실무 체감 비용 |
| --- | --- | --- | --- | --- |
| 기본 메트릭 (요청 수, 토큰, 지연시간) | 없음 — Azure Monitor가 플랫폼 메트릭으로 자동 수집 | Foundry/Cognitive Services 리소스 → Metrics | **무료** (90일 보관, 1분 단위) | 0 |
| 상세 로그 (요청/응답, 콘텐츠 안전, 사용량) | **Diagnostic Settings** + 다음 중 1개 이상의 sink<br>– **Log Analytics Workspace**<br>– Storage Account (장기 보관)<br>– Event Hubs (실시간 스트리밍) | 리소스 → Diagnostic settings | 수집/보관량 기준<br>– Log Analytics: ≈ $2.76/GB ingest + $0.12/GB·월 보관<br>– Storage (cool): GB당 ≈ $0.01/월 | 호출량·페이로드 크기 비례 |
| KQL 쿼리/대시보드 | Log Analytics Workspace (위와 동일) + 선택적 **Azure Workbook**(무료) / **Grafana**(별도) | Azure Portal → Logs / Workbooks | 쿼리 자체는 무료, Premium 보존만 별도 | Workbook은 0, Managed Grafana는 인스턴스 시간 과금 |
| App/Agent 분산 추적 (OpenTelemetry) | **Application Insights** (Log Analytics 기반) | 코드에 OTEL exporter 설정 | 텔레메트리 GB당 ≈ $2.30 (Basic) / $2.76 (Classic) | 추적 샘플링으로 조절 |
| 콘텐츠 안전 (모더레이션) 로그 | Foundry **Content Safety**가 기본 내장 — 호출당 별도 트랜잭션 과금 가능 | Foundry → Safety + Diagnostic logs | $1 정도/1K 텍스트 트랜잭션 (티어 상이) | 사용량 비례 |
| 알림 | **Azure Monitor Alerts** (메트릭/로그 알림) + **Action Group** | Monitor → Alerts | 메트릭 알림 ≈ $0.10/규칙·월, 로그 알림 ≈ $1.50/규칙·월, SMS/음성 별도 | 규칙 수 비례 |
| 비용 분석 | **Azure Cost Management** (기본 무료), **Budgets**, Cost alerts | Cost Management + Billing | 무료 | 0 |
| (옵션) 단일 SIEM | **Microsoft Sentinel** = Log Analytics 위 + Sentinel 분석 비용 | Sentinel 활성화 | 분석 데이터 GB당 ≈ $4.30 (Pay-as-you-go) | 보안 통합 시만 고려 |

> **저비용 출발점**: 메트릭 탭 + Cost Management + Action Group (이메일) 만으로 시작 → 페이로드 감사가 필요해지면 Log Analytics를 붙이고 **샘플링/보존기간**으로 비용 통제. Application Insights는 OTEL 트레이스가 실제로 필요한 시점에 추가.

### 10.3 비교 요약

| 비용 항목 | 현재 (Databricks) | Foundry 직접 |
| --- | --- | --- |
| **공짜로 보이는 것** | Serving Metrics 탭 | Azure Monitor 플랫폼 메트릭, Cost Management |
| **활성화하는 순간 비용** | SQL Warehouse (DBU/시간) | Log Analytics 수집/보관 (GB당) |
| **사용량에 비례** | Inference Tables 저장 (GB) | Diagnostic Logs 수집 (GB) |
| **고정비 위험** | 자동 stop 안 한 SQL Warehouse | 보관기간 길게 잡힌 Log Analytics |
| **세분화된 청구 분해** | DBU 한 줄로 합산 → SKU별 분해 필요 | Cost Management에서 모델/태그/리소스별 분해 즉시 가능 |
| **통합 가능 범위** | Databricks 생태계 내 통합이 1급 | 모든 Azure 리소스(앱, DB, 네트워크 등)와 동일 도구로 통합 |

### 10.4 비용 통제 체크리스트

- **Databricks 측**
  - SQL Warehouse는 **Serverless + Auto-stop 5~10분**으로 설정.
  - Inference Tables는 필요 엔드포인트에만 켜고, **Delta TTL/VACUUM**으로 오래된 파티션 정리.
  - 시스템 테이블 쿼리는 스케줄 잡으로 **요약 테이블**을 미리 만들어 두고 대시보드는 요약을 조회.
- **Foundry 측**
  - Diagnostic Settings에서 **꼭 필요한 카테고리만** Log Analytics로 보내고 나머지는 Storage (cool/archive)로 분리.
  - Log Analytics는 **Daily Cap** 설정과 **Basic Logs / Auxiliary Logs** 티어 활용.
  - Application Insights는 **Adaptive sampling** 또는 **고정 샘플링** 적용.
  - **Azure Budgets**로 월 한도 + Action Group 알림.
  - Sentinel은 정말 SOC가 받을 때만 — 그 외에는 Workbook 대시보드로 충분.

---

## 언제 어느 쪽이 맞나

**현재 방식(Databricks 호스팅)이 적합한 경우**
- 이미 Databricks가 데이터 플랫폼 표준이고, 모델 호출도 같은 보안/네트워크 경계에서 처리하고 싶을 때
- Lakehouse 데이터와 inference 결과를 같은 Delta로 보관·분석할 때 (Inference Tables)
- 엔지니어링·데이터 팀이 모두 Databricks 사용자일 때

**Foundry Models 직접이 적합한 경우**
- 거버넌스/네트워킹/비용 관리를 **Azure 표준 도구**로 일원화하고 싶을 때
- Azure OpenAI 모델(GPT-4.1, o-시리즈 등)을 같은 카탈로그에서 함께 쓰고 싶을 때
- Agent Framework의 Hosted Tools / Foundry Agent Service / Evaluations를 적극 활용할 때
- Entra ID 기반 키리스 인증, Private Endpoint, Content Safety가 컴플라이언스 요건일 때

## 마이그레이션 관점 한 줄

> **Databricks → Foundry로 옮기는 비용은 코드 한 줄(`OpenAIChatCompletionClient` 교체) 수준**이지만, 옮겨가는 즉시 **거버넌스·관측·청구가 Azure Foundry Control Plane으로 통합**됩니다. 반대로 Databricks에 남기면 **데이터 플랫폼과 모델 플랫폼이 한 경계 안**에 머무는 게 가장 큰 이점입니다.
