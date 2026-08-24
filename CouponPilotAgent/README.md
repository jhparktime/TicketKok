# CouponCock ADK Agent

쿠폰콕 MVP의 결정론적 계산 원칙을 유지하면서 Google ADK, MCP, AgentOps를 적용한 고도화 서비스입니다.

## 실행 흐름

`Workflow` 그래프는 의존성이 없는 Agent를 병렬 실행하고, JoinNode가 필요한 결과를 모두 받은 뒤 다음 단계를 시작합니다.

1. `store_context_agent`와 `personalization_agent`를 병렬 실행한다.
2. 매장 맥락 JoinNode 이후 `coupon_understanding_agent`와 `benefit_retrieval_agent`를 병렬 실행한다.
3. 쿠폰·혜택 JoinNode 이후 `recommendation_agent`가 Calculator MCP 결과를 보존해 추천 설명을 생성한다.

가격·절약액·중복 가능 여부는 `calculate_best_discount` MCP Tool만 결정합니다.

모든 Agent는 `completed`, `skipped`, `blocked`, `failed` 상태와 사유·구조화 데이터를 반환합니다. 쿠폰이 없거나 브랜드가 맞지 않으면 Coupon Agent는 `skipped`를 반환하며, 후속 단계는 불필요하게 대기하지 않습니다.

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
