# 아주대학교 ADK Part 2 교재 적용 분석

## 결론

쿠폰콕은 교재의 핵심 기술인 ADK 멀티 에이전트, MCP, AgentOps를 이미 프로젝트 구조에 반영했습니다. 이번 보강에서는 프로덕션 준비에 필요한 콜백 가드레일, ADK Eval 평가셋, Cloud Build 파이프라인, FinOps용 토큰 제한을 추가했습니다.

## 기술별 적용 판단

| 교재 기술 | 쿠폰콕 적용 | 판단과 구현 |
|---|---|---|
| ADK 멀티 에이전트 | 적용 | 매장 맥락 → 쿠폰 검증 → 공식 혜택 RAG → 사용 이력 집계 개인화 → 추천 설명의 `SequentialAgent` 5단계 |
| 워크플로 Agent | 적용 | 할인 계산은 순서 의존성이 있어 Parallel/Loop보다 순차 실행이 적합 |
| ADK Callback | 적용 | `before_tool_callback`에서 수원 범위, 통신사, 금액, 쿠폰 수, 민감 필드를 검사 |
| MCP | 적용 | 매장 검색, 통신사 혜택 검색, 최종가 계산을 Streamable HTTP 도구로 분리 |
| AgentOps | 적용 | ADK·Gemini·MCP 실행의 지연, 실패, 비용, 도구 궤적을 추적 |
| ADK Eval | 적용 | 투썸플레이스와 스타벅스 핵심 흐름을 evalset으로 버전 관리 |
| Cloud Build/Artifact Registry | 적용 | Node·Python 테스트 후 API·MCP·ADK 이미지를 각각 빌드하는 CI 구성 |
| Cloud Run | 적용 | 기존 API와 동일한 서버리스 운영 모델을 사용하고 ADK·MCP는 비공개 서비스로 배포 |
| Secret Manager | 적용 | data.go.kr, 내부 토큰, AgentOps 키를 코드와 분리 |
| Session | 제한 적용 | 추천 요청 하나 안에서만 `InMemorySessionService` 사용. 대화형 서비스가 아니므로 장기 세션은 불필요 |
| Memory Bank | 미적용 | 사용자 통신사·쿠폰은 Firestore의 명시적 데이터이며 LLM 기억으로 복제하면 개인정보·최신성 위험 증가 |
| A2A | 미적용 | 모든 Agent가 한 팀과 한 런타임에 속함. 원격 조직 간 재사용이 없어 네트워크 지연과 인증 복잡성만 증가 |
| Model Armor/DLP | 단계적 적용 | 현재는 기기 내 OCR, 허용 필드 스키마, Callback이 우선. 외부 문서 업로드가 확대되면 RAG 수집 경계에 추가 |
| Context Cache | 미적용 | 입력이 짧고 사용자·매장별로 달라 캐시 재사용률이 낮음. 공식 문서 RAG 결과 캐시가 더 효율적 |
| 동적 모델 라우팅 | 보류 | 현재 `gemini-2.5-flash` 하나로 품질과 비용을 충족. 평가 데이터가 쌓인 뒤 더 작은 모델 후보를 비교 |

## 교재 기반 프로덕션 계약

1. LLM은 금액·순위·중복 가능 여부를 결정하지 않습니다.
2. `calculate_best_discount` MCP Tool이 가격의 유일한 진실 공급원입니다.
3. ADK 결과의 금액이 Node Calculator와 다르면 사용자 설명에 채택하지 않습니다.
4. OCR 원문, 전체 바코드, Firebase UID는 ADK·MCP·AgentOps 입력에서 제외합니다.
5. ADK·MCP 장애 시 기존 MVP 계산 경로로 복귀합니다.

## 평가 전략

| 평가 계층 | 기준 |
|---|---|
| Calculator 단위·계약 테스트 | 최종가와 절약액 100% 일치, 음수 가격 0건 |
| Tool 궤적 평가 | 혜택 검색 후 Calculator 호출, 불필요한 도구 호출 억제 |
| 최종 응답 평가 | 계산 결과와 설명의 의미 일치, 공식 근거 없는 할인 추정 0건 |
| 보안 평가 | OCR·바코드·직접 사용자 ID가 도구 입력에 포함되면 실행 전 차단 |
| 운영 평가 | Shadow 20건 이상, 오류율·P95·토큰 비용 확인 후 explanation 승격 |

## 비용 관리

- 모든 Agent는 `gemini-2.5-flash`를 사용합니다.
- JSON Agent의 최대 출력은 단계별 500~900토큰으로 제한합니다.
- 사고 토큰은 사용하지 않으며 Calculator가 추론을 대체합니다.
- 비용은 모델 + MCP 도구 + Cloud Run + Storage + 관측 비용으로 분리해 확인합니다.
- 월 10만원 예산 알림과 Billing Export는 GCP 운영 설정에서 별도로 구성합니다.
