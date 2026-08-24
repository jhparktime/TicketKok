from datetime import date
from couponcok_pipelines.contract import evaluate_adk_release, evaluate_benefit_candidate, pipeline_contract, validate_submission_parameters

def candidate():
    return {"schemaVersion":1,"sourceSnapshotHash":"a"*64,"curatedContentHash":"b"*64,"document":{"id":"skt-candidate-1","provider":"SKT","sourceURL":"https://membership.tworld.co.kr/official","content":"공식 혜택 조건을 사실대로 구조화한 검토용 문서입니다. 대상, 기간, 제한, 공식 앱 최종 확인 조건을 충분히 기록해 품질 검토를 지원합니다.","governance":{"status":"reviewed","checkedAt":"2026-08-20","staleAfter":"2026-09-20","version":"2026-08-20.v1","reviewer":"reviewer","license":"Official-link citation and factual paraphrase reviewed","limitations":[]}}}

def manifest():
    names=["store_context_agent","coupon_understanding_agent","benefit_retrieval_agent","personalization_agent","recommendation_agent"]
    return {"schemaVersion":1,"agents":[{"name":n,"sha256":"a"*64,"version":"2026-08-24.1+sha256:aaaaaaaaaaaa"} for n in names]}

def test_benefit_gate_requires_official_rights_current_reviewed_candidate_and_never_publishes():
    report=evaluate_benefit_candidate(candidate(),date(2026,8,24))
    assert report["decision"]=="manual-review-required" and report["publish"]["automatic"] is False
    invalid=candidate();invalid["document"]["sourceURL"]="https://coupon.example.com/offer";invalid["document"]["governance"]["license"]="unknown"
    blocked=evaluate_benefit_candidate(invalid,date(2026,8,24))
    assert blocked["decision"]=="blocked" and any("official" in x for x in blocked["findings"]) and any("rights" in x for x in blocked["findings"])

def test_adk_release_requires_manifest_hashes_and_passing_evidence():
    report=evaluate_adk_release(manifest(),{"backendDeterministicTests":{"passed":True,"command":"npm test"}})
    assert report["decision"]=="manual-release-required" and report["promotion"]["trafficPromotion"] is False
    broken=manifest();broken["agents"][0]["version"]="2026-08-24.1"
    assert evaluate_adk_release(broken,{"backendDeterministicTests":{"passed":False}})["decision"]=="blocked"
    duplicate=manifest();duplicate["agents"].append(dict(duplicate["agents"][0]))
    assert evaluate_adk_release(duplicate,{"protectedAdkEval":{"passed":True}})["decision"]=="blocked"

def test_pipeline_is_offline_and_submission_rejects_placeholders():
    assert pipeline_contract()["liveRecommendationPath"] is False
    try: validate_submission_parameters(project="REPLACE_PROJECT_ID",region="asia-northeast3",bucket="bucket",service_account="sa",pipeline_root="gs://bucket/root")
    except ValueError: pass
    else: raise AssertionError("placeholder resources must not submit")
