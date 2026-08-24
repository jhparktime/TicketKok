# 쿠폰콕 API·서비스 인벤토리

기준일: 2026-08-20
범위: TicketCock 기준 현재 구현, 배포 전 활성화 대기, 비교 저장소에서 확인한 보조 API

## 1. 현재 앱·백엔드에서 사용하는 API와 프레임워크

| 구분 | API/서비스 | 호출 주체 | 용도 | 민감정보·비용 경계 | 상태 |
|---|---|---|---|---|---|
| 매장 공공 데이터 | 소상공인시장진흥공단 상가(상권)정보 API `sdsc2` | Cloud Run API | 수원 반경 내 지원 프랜차이즈 매장 식별 | 서비스 키는 Secret Manager, 10분 서버 캐시, 데이터셋 ID `15012005` 계보 반환 | 사용 중 |
| 기기 위치 | Apple Core Location | iPhone | 현재 위치·지오펜스·5분 재진입 제한 | 장기 위치 이력 서버 저장 금지 | 사용 중 |
| 기기 POI 보완 | Apple MapKit Local Search | iPhone | 공공 API 지연·누락 시 빠른 주변 매장 후보 | API 키 없음, 후보 확인용 | 사용 중 |
| 외부 지도 MCP | Google Maps Grounding Lite MCP | Private MCP Cloud Run | 매장명·주소 후보의 보조 검증 | 0.01도 격자 좌표와 매장명만 전달, `mapstools.googleapis.com` 전용 Secret Manager 키 | Test 후보 사용 중 |
| 외부 지도 fallback | Kakao Local REST API | Private MCP Cloud Run | Google Maps MCP 응답 불가 시 국내 장소 후보 보완 | 공식 REST 키가 등록될 때만 활성화, 정밀 GPS·전화번호 미전송·미저장 | 코드 준비 |
| 알림 | Apple UserNotifications | iPhone | 매장 진입 로컬 알림·추천 화면 복귀 | 사용자 권한 필요 | 사용 중 |
| OCR | Apple Vision | iPhone | 쿠폰·카드 이미지 텍스트 추출 | 원본 이미지는 기기 내부 보관 | 사용 중 |
| 인증 | Firebase Authentication | iPhone·Cloud Run | 익명 사용자 인증·ID 토큰 검증 | Firebase UID 원문은 Agent에 전달 금지 | 사용 중 |
| 앱 무결성 | Firebase App Check / App Attest | iPhone·Cloud Run | 정품 앱·기기 attestation | 현재 monitor, 실기기 검증 뒤 enforce | 사용 중 |
| 사용자 데이터 | Cloud Firestore | iPhone·Cloud Run | 프로필·쿠폰·사용/복원 기록 | 사용자 소유 경로·규칙 적용 | 사용 중 |
| AI 생성·임베딩 | Vertex AI Gemini 2.5 Flash / embedding | Cloud Run·ADK | 쿠폰 OCR 구조화, 카드 상품 카탈로그 분류, 근거 유형 설명, 공식 혜택 임베딩 | 카드 뒷면은 기기 내 OCR 전용. 명시 동의 시 앞면은 기기에서 전체 텍스트·하단 민감 영역을 픽셀 마스킹하고 Vision 재검사한 시각 서명만 1회 전달한다. Cloud DLP가 모든 텍스트를 재마스킹한 결과만 Gemini에 전달한다. Calculator가 금액·순위의 유일한 권한 | 사용 중 |
| 공식 문서 | Cloud Storage | Benefit ingest·RAG | 공식 혜택 원문 snapshot·버전·인덱스 | candidate→approve→active만 검색 가능 | 사용 중 |
| 비밀 관리 | Secret Manager | Cloud Run | data.go.kr·내부 MCP·가명화 키 주입 | 코드·iOS 앱에 키 미기록 | 사용 중 |
| API 진입점 | API Gateway + Cloud Run | iPhone·백엔드 | Firebase 인증 요청만 API로 전달 | Cloud Run IAM과 토큰 검증 이중 경계 | 사용 중 |
| Agent Tool 계약 | Streamable HTTP MCP | ADK → MCP Cloud Run | 매장 검색·외부 지도 검증·공식 혜택 검색·가격 계산 | read-only 4 Tool, strict schema | 사용 중 |
| 멀티에이전트 | Google ADK | Private Cloud Run | 매장·쿠폰·혜택·설명 순차 오케스트레이션 | shadow 기본, Calculator 결과 불변 | 사용 중 |
| 관측 | OpenTelemetry / Cloud Logging / AgentOps | 백엔드·ADK | 비식별 latency·Tool 순서·비용 추적 | AgentOps 키 미주입 시 비활성 | 코드 준비 |

## 2. 안전 API: 활성화 상태와 출시 조건

| API/서비스 | 현 상태 | 런타임 모드 | 출시 전 필요 조건 |
|---|---|---|---|
| Sensitive Data Protection (Cloud DLP) | `dlp.googleapis.com` 활성화, API Test SA `roles/dlp.user` | Test 후보 `enforce` | 지정 infoType만 검사, 프로덕션 승격 전 오탐률 확인 |
| Model Armor | `modelarmor.googleapis.com` 활성화, 서울 템플릿 생성, ADK/API Test SA `roles/modelarmor.user` | Test 후보 `enforce` | 서울은 기본 템플릿만 지원. 인젝션·URI·RAI는 앱 Guardrail과 DLP fail-closed로 보완 |
| App Check | 코드·iOS provider 준비 | monitor | 실기기 App Attest와 Debug provider 관측 후 enforce |

Cloud DLP는 OCR 자유 텍스트에서 `EMAIL_ADDRESS`, `PHONE_NUMBER`, `CREDIT_CARD_NUMBER`처럼 필요한 detector만 사용한다. Model Armor는 사용자/Agent prompt와 최종 모델 응답을 검사하되, Calculator·Firestore 상태 변경 경로에는 사용하지 않는다.

## 3. 비교 저장소에서 확인한 외부 API

| 저장소 | 확인된 API/서비스 | 채택 판단 |
|---|---|---|
| `zaeee-wang/CouponKok` | data.go.kr `sdsc2`, Google Places Nearby Search, Google Maps SDK | 공공 카탈로그를 배치 동기화하고 POI 검색을 서버에서 보완하는 패턴은 참고. Google Places는 비용을 별도 통제해야 함 |
| `guddn/Coupon_Kock` | data.go.kr `sdsc2`, Google Maps 설정 | 주변 매장 조회는 data.go.kr 중심. API 실패 시 무표시 fixture 폴백은 TicketCock에서 채택하지 않음 |
| `wkdwotjr/Gen_AI_MVP` | Kakao Maps JavaScript SDK | 지도 렌더링에는 적합. `KAKAO_LOCAL`은 보조·미저장 출처로 설계되어 있으며, 쿠폰 할인 근거로는 사용하지 않음 |
| `heon0109-k/coupon-kok` | Gemini, Firestore 시드 매장 | 매장·혜택 후보가 시드 데이터 중심이므로 공공 매장 식별에는 보완 필요 |

## 4. 카카오 Local API 도입 원칙

카카오 Local API는 TicketCock의 data.go.kr를 **대체하지 않고 보완**한다.

1. data.go.kr를 장기 매장 카탈로그와 출처 기준으로 유지한다.
2. 카카오 키워드/카테고리 검색은 공공 매장 캐시 미스, 지점명 모호성, 사용자의 수동 검색 때만 Cloud Run에서 호출한다.
3. API 결과는 `placeId`, 이름, 주소, 좌표, 거리, 검색 시각만 최소 보관한다. 전화번호는 저장·Agent 전달하지 않는다.
4. 카카오 단독 후보는 `unverified`로 두고, 사용자 확인 또는 공공 데이터 매칭 뒤에만 지오펜스 후보로 승격한다.
5. 키는 iOS에 넣지 않고 Secret Manager에서 Cloud Run에 주입한다. 호출당 비용·쿼터는 FinOps 예산 알림으로 통제한다.

카카오 장소 검색은 공공 매장 API가 답하지 못하는 최신 지점명·POI 검색을 보완하지만, 통신사·카드·쿠폰의 중복 가능 여부나 최종 할인금액을 제공하지 않는다.

## 5. 쿠폰콕이 노출하는 내부 API 계약

| Method | Endpoint / Tool | 호출자 | 역할 | 권한·데이터 경계 |
|---|---|---|---|---|
| GET | `/health`, `/ready` | 운영·Cloud Run | liveness/readiness 확인 | 비밀·사용자 데이터 미반환 |
| GET | `/v1/stores/nearby` | iOS | 좌표 기반 수원 지원 프랜차이즈 목록 | Firebase 인증, data.go.kr 출처 메타 포함 |
| GET | `/v1/benefits/search` | iOS·ADK | 공식 혜택 RAG 검색 | `active`·권리 검토 완료 문서만 반환 |
| POST | `/v1/coupons/normalize` | iOS | Vision OCR 결과를 쿠폰 구조로 정규화 | 이미지 제외, DLP 가명화 후 Gemini 전달 |
| POST | `/v1/cards/recognize` | iOS | 앞·뒷면 촬영 후 지원 카드 상품 후보·공식 안내 링크 확인 | 명시 동의, 기기에서 전체 텍스트·하단 영역을 가리고 Vision 재검사한 앞면 시각 서명만 전달. DLP가 모든 텍스트를 재마스킹한 결과만 Gemini 전달하며, PAN·CVC·유효기간·뒷면 원본은 거부하고 사용자 확인 후에만 프로필 저장 |
| POST | `/v1/recommendations` | iOS | 후보 필터·RAG·Calculator·설명 조합 | Firebase ID Token, 금액은 Calculator 결과만 사용 |
| POST | `/mcp` (`search_nearby_stores`) | ADK | 매장 후보·출처 조회 | 내부 MCP 토큰, read-only |
| POST | `/mcp` (`verify_store_with_external_maps`) | ADK | Google Maps 공식 MCP 보조 검증, 카카오 공식 REST fallback | 0.01도 격자 좌표만 전송, 할인·지오펜스 결정 불가 |
| POST | `/mcp` (`retrieve_carrier_benefits`) | ADK | 통신사·카드 공식 근거 조회 | 내부 MCP 토큰, active 문서만 |
| POST | `/mcp` (`calculate_best_discount`) | ADK | 최종가·절약액 결정론 계산 | 내부 MCP 토큰, 상태 변경 없음 |
| POST | ADK `/v1/orchestrate` | Backend | 5개 Agent 순차 오케스트레이션 | 내부 ADK 토큰, 원문 OCR·UID·원본 구매 이력 스키마 차단 |

외부 API 키는 iOS·Git에 두지 않고 Secret Manager 또는 런타임 Workload Identity/서비스 계정으로만 접근한다. API Gateway는 사용자 API의 경계이며, MCP·ADK는 공개 인터넷 호출자가 아닌 Cloud Run 내부 서비스 간 경계로 유지한다.
