# 쿠폰콕 초개인화·카드 OCR·위치·FinOps 설계

- 버전: 2026-08-20.v1
- 목적: 상용화 기능을 개인정보 최소수집과 비용 통제 안에서 확장

## 1. 초개인화 원칙

쿠폰콕의 초개인화는 사용자의 소비성향을 추측하는 광고 프로파일링이 아니라, 사용자가 직접 제공한 정보와 현재 결제 맥락으로 **사용 가능한 후보를 좁히는 기능**이다.

| 신호 | 사용 목적 | 동의 | 가격 결정 영향 |
|---|---|---|---|
| 보유 쿠폰·만료일·사용 상태 | 현재 매장 후보와 만료 임박 알림 | 서비스 필수 처리 | Calculator 입력 |
| 통신사·등급·월 사용 여부 | 공식 멤버십 후보 필터 | 선택 초개인화 | 공식 규칙이 있을 때만 Calculator 입력 |
| 카드사·상품명·실적 충족·잔여 한도 | 카드 혜택 후보 필터 | 선택 초개인화 | 공식 규칙이 있을 때만 Calculator 입력 |
| 현재 매장·시간 | 사용처·시간 조건 검증 | 선택 위치 개인화 | 공식 조건 검증 |
| 사용 완료 이력 | 자주 사용하는 브랜드·만료 임박 쿠폰의 추천 우선순위 | 선택 초개인화 | Calculator 가격 순위는 보존하고, 비용 차이를 표시한 개인화 추천 우선순위를 조정 |

초개인화가 꺼지면 통신사·카드 프로필은 초기화하고 API에는 빈 프로필을 전송한다. 쿠폰 자체의 할인액과 만료일 관리는 계속 제공한다.

### 추천의 두 단계

1. **자격·가격 단계**: 브랜드, 만료, 최소금액, 공식 멤버십 조건을 hard filter한 뒤 Calculator가 최종가를 산정한다.
2. **개인화 추천 단계**: 동의된 집계로 만료 임박·사용 빈도·방문 주기를 점수화해 표시 우선순위를 조정한다. 가격 기준 1위와 최종가 차이를 함께 표시하고, 사용자는 언제든 최대 절약안을 선택한다.

사용 선호가 더 비싼 방법을 최대 절약안으로 오인시키지 않는다. 금액 순위와 개인화된 표시 우선순위를 분리하고, 비용 차이와 근거를 함께 제공한다.

## 2. 로그인과 개인정보 동의

로그인은 동의가 아니다. 앱은 다음을 독립적으로 기록한다.

| 항목 | 성격 | 거부 시 |
|---|---|---|
| 익명 ID·쿠폰·사용 기록 처리 | 필수 | 클라우드 동기화·추천 서비스를 시작하지 않음 |
| 쿠폰·멤버십 초개인화 | 선택 | 통신사·카드 개인화 없이 쿠폰 단독 계산 |
| 매장 진입 위치 개인화 | 선택 | 자동 지오펜스·알림 미사용, 직접 쿠폰 관리 가능 |

동의 레코드는 policyVersion, required/optional 상태, acceptedAt을 기기와 사용자 소유 Firestore 경로에 저장한다. 정책 버전이 바뀌면 새 화면에서 다시 확인한다. 내 정보에서 선택 동의를 철회할 수 있고, 계정 및 모든 데이터 삭제 시 동의 레코드도 삭제한다.

현재 구현:

- `PrivacyConsentView`: 필수·선택 항목 분리
- `PrivacyConsent`: 정책 버전과 동의 시각
- `users/{uid}/consents/{policyVersion}`: 사용자 소유 동의 증적
- `updateOptionalConsents`: 선택 동의 철회 및 프로필 초기화

## 3. 멀티모달 카드 인식

카드 인식 목표는 결제정보 수집이 아니라 **카드 상품 선택 시간을 줄이는 것**이다.

```text
카드 이미지 선택
  → iPhone Vision OCR
  → 긴 숫자열 탐지·즉시 폐기
  → 카드사/상품명 키워드만 allowlist 매칭
  → 사용자 확인
  → productId만 프로필 저장
```

수집·저장하지 않는 항목:

- 카드번호(PAN)
- 유효기간
- CVC/CVV
- 카드 소유자명
- 승인·거래내역
- 카드 원본 이미지
- 전체 OCR 텍스트

현재는 신한카드 Mr.Life, KB국민 톡톡 Pay카드, 현대카드 M을 기기 내에서 인식한다. 인식 실패 시 사용자가 목록에서 직접 선택하며, LLM이 상품명을 추측하지 않는다. 향후 Vision 기반 카드 디자인 분류 모델을 사용하더라도 기기 내 Core ML 모델로 배포하고, 서버 멀티모달 업로드는 기본 경로로 채택하지 않는다.

## 4. 위치 기반 정보 수집

### 4.1 하이브리드 매장 디렉터리

| 단계 | 데이터 | 역할 |
|---|---|---|
| 1 | Core Location | 사용자의 현재 좌표와 지오펜스 진입 이벤트 |
| 2 | MapKit 주변 검색 | 현재 위치에서 즉시 지원 프랜차이즈 후보 확보 |
| 3 | data.go.kr 상가업소 API | 수원 매장명·주소·업종·좌표 원천 보완 |
| 4 | Firestore directory cache | 외부 API 장애·쿼터에 대비한 10분 지역 캐시 |
| 5 | iOS geofence | 거리순 최대 20개 매장 등록 |

기기에서는 250m 이상 이동하거나 2분이 지난 경우에만 매장 디렉터리를 갱신한다. 같은 매장은 이탈 후 5분 이내 재진입 시 알림을 반복하지 않는다.

### 4.2 위치 한계와 대응

- iOS 지역 모니터링은 앱당 최대 20개이므로 거리순 후보를 표시하고 갱신한다.
- GPS는 고층·복합몰에서 층을 구분하지 못한다. 해당 환경에서는 매장명을 알림에서 재확인하거나 사용자가 지점을 선택하도록 한다.
- 상용 확장 시 쇼핑몰·다층 매장은 BLE beacon, 매장 Wi-Fi, QR/NFC 체크인 중 하나를 제휴 방식으로 추가한다.
- 위치 좌표와 이동 경로를 서버 사용자 이력으로 저장하지 않는다.
- `Always` 권한은 위치 개인화 동의와 가치 설명 뒤 별도로 요청한다.

## 5. FinOps

### 5.1 베타 예산 정책

초기 베타 권장 월 예산은 100,000원이며 다음 경보를 둔다.

| 임계치 | 조치 |
|---|---|
| 50% | 서비스별 비용 추세와 비정상 요청 확인 |
| 80% | ADK shadow 10%→0%, 비필수 embedding/재색인 중단 |
| 100% | Gemini OCR 정규화를 일시적으로 기기 내 초안+사용자 편집으로 전환 |
| 120% 예측 | 신규 가입 제한 또는 운영자 승인 후 예산 변경 |

Budget 알림은 비용을 자동 차단하지 않으므로 Cloud Monitoring 알림과 애플리케이션 feature flag를 함께 사용한다.

### 5.2 단위경제 관측

| 비용 단위 | 관측 키 |
|---|---|
| AI 구조화·설명 | operation, model, promptTokens, outputTokens, totalTokens |
| Embedding | model, items, documentVersion |
| Cloud Run | service, revision, requestCount, instanceSeconds |
| Firestore | reads, writes, rateLimit transaction count |
| 공공 API | dataGo call count, cache hit/miss, error rate |
| Agent | adkMode, sampled/completed/failed, tool call count, duration |

`finops.ai_usage` 구조화 로그에는 텍스트·UID·쿠폰번호를 넣지 않는다. 비용은 Cloud Billing Export의 실제 SKU 금액과 조인한다.

### 5.3 구현된 비용 통제

- Gemini 2.5 Flash, temperature 0, 추천 분류 최대 100 output token
- OCR 정규화 최대 700 output token
- ADK shadow는 request ID 기반 결정론적 10% 샘플링
- 사용자별 OCR 30회/일, 추천 120회/일, 혜택 검색 120회/일 쿼터
- 응답에 quota limit/remaining header 제공
- 매장 디렉터리 10분 캐시와 기기 250m/2분 throttle
- RAG 문서는 ingest 시 한 번 임베딩하고 런타임 API는 read-only
- Cloud Run min instance 0, API max 3, MCP·ADK max 2
- ADK/RAG 장애 시 쿠폰 단독 Calculator로 fallback

### 5.4 다음 FinOps 작업

1. BigQuery Cloud Billing Export 활성화
2. 서비스·환경·owner·costCenter 라벨 강제
3. `finops.ai_usage`와 Billing Export를 조인한 일별 대시보드
4. cache hit ratio, 사용자당 AI 비용, 성공 추천당 비용 측정
5. 예산 임계치 Pub/Sub → feature flag 자동 조정은 오작동 방지 승인 절차 후 도입
6. 30일마다 model/version별 품질 대비 비용 재평가
