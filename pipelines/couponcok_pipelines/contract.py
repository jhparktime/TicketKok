"""Pure, deterministic decisions used by offline gate components and tests."""
from __future__ import annotations
import re
from datetime import date
from urllib.parse import urlparse

OFFICIAL_DOMAINS={"SKT":("tworld.co.kr",),"KT":("kt.com",),"LG U+":("lguplus.com",),"신한카드 Mr.Life":("shinhancard.com",),"KB국민 톡톡 Pay카드":("kbcard.com",),"현대카드 M":("hyundaicard.com",)}
PROMPT_AGENTS={"store_context_agent","coupon_understanding_agent","benefit_retrieval_agent","personalization_agent","recommendation_agent"}

def _date(value: object, findings: list[str], name: str) -> date | None:
    try: return date.fromisoformat(str(value))
    except ValueError: findings.append(f"{name} must be YYYY-MM-DD"); return None

def _official(provider: object, source: object) -> bool:
    parsed=urlparse(str(source)); host=parsed.hostname or ""
    return parsed.scheme=="https" and any(host==domain or host.endswith("."+domain) for domain in OFFICIAL_DOMAINS.get(str(provider),()))

def evaluate_benefit_candidate(candidate: dict[str, object], today: date | None=None) -> dict[str, object]:
    """Applies the same official-domain/rights/lifecycle/staleness policy as RAG ingestion; never publishes."""
    today=today or date.today(); findings: list[str]=[]; d=candidate.get("document") if isinstance(candidate.get("document"),dict) else {}; g=d.get("governance") if isinstance(d.get("governance"),dict) else {}
    if candidate.get("schemaVersion") != 1: findings.append("schemaVersion must be 1")
    for key in ("sourceSnapshotHash","curatedContentHash"):
        if not isinstance(candidate.get(key),str) or not re.fullmatch(r"[0-9a-f]{64}",candidate[key]): findings.append(f"{key} must be SHA-256")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-_]{0,127}",str(d.get("id",""))): findings.append("document.id must be stable ASCII")
    if not isinstance(d.get("content"),str) or len(d["content"].strip())<60: findings.append("document.content must contain at least 60 characters")
    if not _official(d.get("provider"),d.get("sourceURL")): findings.append("sourceURL is not on provider official-domain allowlist")
    checked=_date(g.get("checkedAt"),findings,"checkedAt"); stale=_date(g.get("staleAfter"),findings,"staleAfter")
    if checked and checked>today: findings.append("checkedAt cannot be in the future")
    if stale and checked and stale<checked: findings.append("staleAfter must not precede checkedAt")
    if stale and stale<today: findings.append("candidate is stale")
    if g.get("status") not in {"draft","reviewed"}: findings.append("candidate lifecycle must be draft or reviewed; active is forbidden")
    if not isinstance(g.get("version"),str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",g["version"]): findings.append("immutable governance.version required")
    if not isinstance(g.get("reviewer"),str) or not g["reviewer"].strip(): findings.append("reviewer required")
    if not isinstance(g.get("license"),str) or not g["license"].strip() or re.search(r"unknown|pending|unreviewed|미확인|검토\s*중|미정",g["license"],re.I): findings.append("reviewed usage-rights decision required")
    return {"gate":"benefit_rag","decision":"blocked" if findings else "manual-review-required","findings":findings,"quality":{"contentChars":len(str(d.get("content","")).strip()),"hasCalculatorRule":isinstance(d.get("rule"),dict),"stale":bool(stale and stale<today)},"publish":{"automatic":False,"activePromotion":False,"requiredAction":"independent reviewer must run approve:benefit"}}

def evaluate_adk_release(manifest: dict[str, object], evidence: dict[str, object]) -> dict[str, object]:
    findings=[]; names=set()
    entries=manifest.get("agents",[]) if isinstance(manifest.get("agents"),list) else []
    if manifest.get("schemaVersion") != 1: findings.append("prompt manifest schemaVersion must be 1")
    if len(entries) != len(PROMPT_AGENTS): findings.append("exactly five prompt entries required")
    for item in entries:
        if not isinstance(item,dict): findings.append("invalid prompt entry"); continue
        names.add(item.get("name")); digest=item.get("sha256",""); version=item.get("version","")
        if not isinstance(digest,str) or not re.fullmatch(r"[0-9a-f]{64}",digest) or not isinstance(version,str) or not version.endswith("+sha256:"+digest[:12]): findings.append("prompt version/hash mismatch")
    if names!=PROMPT_AGENTS: findings.append("exact five-agent workflow names required")
    backend=evidence.get("backendDeterministicTests",{}) if isinstance(evidence.get("backendDeterministicTests"),dict) else {}; protected=evidence.get("protectedAdkEval",{}) if isinstance(evidence.get("protectedAdkEval"),dict) else {}
    if backend.get("passed") is not True and protected.get("passed") is not True: findings.append("passing backend test or protected ADK eval evidence required")
    return {"gate":"adk_release","decision":"blocked" if findings else "manual-release-required","findings":findings,"metrics":{"backendDeterministicTests":backend,"protectedAdkEval":protected},"promotion":{"automatic":False,"trafficPromotion":False,"requiredAction":"human approver review"}}

def pipeline_contract() -> dict[str, object]:
    return {"name":"couponcok-governance-gates","execution":"batch-offline-only","liveRecommendationPath":False,"parameters":["candidate_manifest_uri","prompt_manifest_uri","evaluation_evidence_uri","prompt_version","rag_version","model_version","pipeline_mode"],"modes":{"benefit_rag":["candidate_validation","quality_report","manual_publish_artifact"],"adk_release":["prompt_hash_check","evaluation_evidence_gate","manual_release_artifact"]},"promotion":"manual-operator-action-required"}

def validate_submission_parameters(*,project:str,region:str,bucket:str,service_account:str,pipeline_root:str)->None:
    missing=[k for k,v in {"project":project,"region":region,"bucket":bucket,"service_account":service_account,"pipeline_root":pipeline_root}.items() if not v or "REPLACE" in v]
    if missing: raise ValueError(f"missing concrete submission parameters: {', '.join(missing)}")
    if not pipeline_root.startswith("gs://"): raise ValueError("pipeline_root must be a gs:// bucket path")
