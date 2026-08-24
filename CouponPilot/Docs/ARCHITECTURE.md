# CouponCock 아키텍처

```text
iOS (SwiftUI)
 ├─ Vision OCR: 쿠폰 이미지 → raw text (이미지는 앱 내부 보관)
 ├─ MapKit + Core Location: 초기 매장 탐색과 매장 반경 진입 이벤트
 └─ Firebase ID Token → API Gateway → Cloud Run Node API
                                      ├─ 기존 결정론적 추천 경로
                                      └─ ADK Orchestrator (shadow → explanation)
                                           ├─ Store Context Agent
                                           ├─ Coupon Understanding Agent
                                           ├─ Benefit Retrieval Agent
                                           ├─ Personalization Agent
                                           └─ Recommendation Agent
                                                 ↓ Streamable HTTP MCP
                                      CouponCock MCP Cloud Run
                                           ├─ search_nearby_stores
                                           ├─ retrieve_carrier_benefits (통신사·카드 공식 근거)
                                           └─ calculate_best_discount
                                                 ↓
                               Firestore · Cloud Storage · data.go.kr · Vertex AI

Cloud Logging/OpenTelemetry: 현재 API·MCP 실행 지연과 실패 관측. AgentOps는 API 키를 Secret Manager에 등록한 뒤 활성화하는 선택 확장 기능입니다.
ADK Callback: MCP 호출 전 지역·금액·민감 필드 정책 검사
ADK Eval + Cloud Build: 응답·도구 궤적 평가 후 컨테이너 이미지 빌드
```

## 에이전트 전환 전략

1. `off`: 기존 MVP 경로만 사용합니다.
2. `shadow`: ADK를 실행해 AgentOps Trace와 기존 결과를 비교하지만 사용자 응답은 바꾸지 않습니다.
3. `explanation`: ADK 결과의 `finalPrice`와 `savings`가 Calculator 결과와 정확히 일치할 때만 설명 문구를 채택합니다.

어떤 모드에서도 ADK·Gemini는 Calculator가 확정한 금액, 순위, 중복 가능 여부를 바꿀 수 없습니다.

## 서비스 계정 최소 권한

| 실행 주체 | 필요한 역할 | 허용 범위 |
|---|---|---|
| API Gateway SA | Cloud Run Invoker | Node API 한 서비스만 호출 |
| Node API Runtime SA | Datastore User, Secret Accessor, Vertex AI User | Firestore와 지정 Secret·Gemini |
| ADK Runtime SA | Cloud Run Invoker, Secret Accessor, Vertex AI User | MCP 서비스 호출과 ADK용 Secret·Gemini |
| MCP Runtime SA | Datastore User, Storage Object Viewer, Secret Accessor, Vertex AI User | 매장 캐시·혜택 버킷·지정 Secret·임베딩 |
| RAG Ingest SA | Storage Object Creator | 혜택 버킷의 문서·인덱스 생성 |

Owner·Editor 역할은 사용하지 않습니다. 사용자 요청 진입 계정과 내부 Agent/MCP 실행 계정을 분리하며, 원본 쿠폰 이미지·전체 바코드·OCR 원문은 AgentOps Trace에 보내지 않습니다.

## 수원시 매장 동기화

1. Cloud Run이 공공데이터포털 `소상공인시장진흥공단_상가(상권)정보_API`의 `storeListInRadius`를 호출합니다.
2. 수원시 경계 안의 상가만 `stores`에 upsert합니다. 데이터에는 상호명, 업종, 주소, 경도·위도가 제공됩니다.
3. iOS는 사용자 쿠폰 프랜차이즈를 MapKit으로 즉시 탐색해 지오펜스를 먼저 등록하고, Cloud Run의 공공데이터 결과로 보완합니다. 공공데이터 API 키는 절대 iOS에 넣지 않습니다.

데모 초기 범위는 수원시청 중심 반경 1.5km와 카페·편의점 업종입니다. 이후 수원시 전체 구역으로 확장합니다.

## Firestore 쿠폰 분리

```text
users/{uid}/coupons/{couponId}       # `status: active`인 추천 후보
users/{uid}/usedCoupons/{historyId}  # 사용 완료 이력, 추천·계산 입력에서 제외
```

`usedCoupons`에는 전체 바코드·쿠폰 이미지·카드사 거래내역을 저장하지 않습니다. 사용자가 결제 완료를 확인한 경우에만 브랜드·상품명·사용 시점과 추천 화면에서 확인한 최종가·절약액을 최소 구매 요약으로 기록합니다. Personalization Agent에는 원본 이력이 아니라 최근 180일의 브랜드별 사용 횟수·마지막 사용 후 경과일·평균 간격만 전달합니다.

## 카드·은행 혜택 확장 원칙

- 앱은 **카드번호·유효기간·CVC·결제내역·계좌 잔액을 수집하지 않습니다.** 사용자가 직접 고른 카드 상품명, 전월 실적 충족 여부, 카드사 앱에서 확인한 남은 월 할인 한도만 `users/{uid}`에 저장합니다.
- Cloud Storage RAG에는 카드사·은행의 **공식 혜택 페이지**만 넣고 원문 링크·확인일·적용 조건을 함께 반환합니다.
- Calculator는 공식 문서에서 할인율·상한·시간·중복 가능 여부가 모두 구조화된 경우에만 가격을 계산합니다. 불명확한 혜택은 출처와 조건만 보여주며 현금 가치로 환산하지 않습니다.
- Open Banking·마이데이터는 인가된 사업자와 이용자 동의가 필요한 제도권 연동이므로, MVP에서는 직접 연동하지 않습니다.

현재 계산 대상은 신한카드 Mr.Life의 야간 식음료 할인입니다. KB국민 톡톡 Pay카드와 현대카드 M은 공식 근거 검색 대상이며, 결제수단·포인트 사용 조건이 확정되기 전에는 계산하지 않습니다.

## LLM 가드레일

- LLM은 쿠폰 이미지에 접근하지 않습니다. iPhone이 OCR한 raw text만 전송합니다.
- LLM은 OCR 텍스트만 구조화 초안으로 반환하며 원문은 저장하지 않습니다. 사용자가 확인한 구조화 필드만 Firestore에 저장합니다.
- ADK 요청 스키마는 허용되지 않은 필드를 거부하고, `before_tool_callback`은 OCR 원문·바코드·직접 사용자 ID가 MCP로 전달되기 전에 차단합니다.
- 금액·할인 한도·중복 적용 가능 여부는 계산기 Tool 또는 정규화된 공식 혜택 규칙으로 판정합니다.
- RAG는 Cloud Storage의 공식 문서 chunk와 출처 URI를 함께 반환하도록 구현합니다.
- Gemini 모델은 `gemini-2.5-flash`로 고정하고, OCR raw text 정규화와 계산 결과 설명에만 사용합니다.
