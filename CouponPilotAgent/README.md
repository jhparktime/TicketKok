# CouponCock ADK Agent

쿠폰콕 MVP의 결정론적 계산 원칙을 유지하면서 Google ADK, MCP, AgentOps를 적용한 고도화 서비스입니다.

## 실행 흐름

1. `store_context_agent`: 대한민국 내 지원 매장 맥락 확인
2. `coupon_understanding_agent`: 등록 쿠폰 후보 검증
3. `benefit_retrieval_agent`: 통신사·카드 공식 혜택 RAG 검색
4. `personalization_agent`: 동의된 사용 이력 집계로 방문 주기·만료 위험 해석
5. `recommendation_agent`: Calculator MCP 결과를 보존해 추천 설명 생성

가격·절약액·중복 가능 여부는 `calculate_best_discount` MCP Tool만 결정합니다.

ADK의 `before_tool_callback`이 민감 필드, 대한민국 서비스 범위, 통신사, 결제금액과 쿠폰 수를 네트워크 호출 전에 검사합니다. 개인화 Agent에는 원본 구매 이력이 아니라 브랜드별 횟수·사용 간격 집계만 전달합니다. 각 Agent의 출력 토큰은 500~900개로 제한합니다.

## 로컬 실행

먼저 `CouponPilotBackend`의 MCP 서버를 8081 포트에서 실행합니다.

```bash
PORT=8081 MCP_INTERNAL_TOKEN=local-demo-token npm run start:mcp
```

이 디렉터리에서 환경변수를 설정하고 ADK 개발 서버를 실행합니다.

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .
adk web .
```

## 평가

스키마·가드레일 테스트는 외부 모델 호출 없이 실행됩니다.

```bash
python -m pytest -q tests
```

스테이징 MCP와 Vertex AI가 준비된 뒤 라이브 ADK 평가를 실행합니다.

```bash
adk eval couponcok_agent evals/couponcok_mvp.evalset.json \
  --config_file_path evals/test_config.json
```

## 최소 권한 배포

- ADK 서비스 계정: Vertex AI User, MCP Cloud Run Invoker
- MCP 서비스 계정: Datastore User, Storage Object Viewer, Secret Accessor
- RAG 적재 계정: Storage Object Creator
- `MCP_INTERNAL_TOKEN`, `AGENTOPS_API_KEY`는 Secret Manager로 주입

ADK와 MCP Cloud Run은 외부 공개 호출을 허용하지 않고, 기존 API Gateway 뒤의 Node API만 iOS 요청을 받습니다.
