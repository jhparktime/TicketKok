"""Functional KFP v2 offline gates: JSON artifacts only, no active publish or traffic promotion."""
from kfp import dsl

@dsl.component(base_image="python:3.12-slim",packages_to_install=["google-cloud-storage==3.13.1"])
def benefit_rag_gate(candidate_manifest_uri:str,report_path:dsl.OutputPath(str),decision_path:dsl.OutputPath(str))->None:
    import json,re
    from datetime import date
    from urllib.parse import urlparse
    from google.cloud import storage
    def read(uri):
        if uri.startswith("gs://"):
            b,n=uri[5:].split("/",1); return storage.Client().bucket(b).blob(n).download_as_text()
        if uri.startswith("file://"): return open(uri[7:],encoding="utf-8").read()
        raise ValueError("candidate_manifest_uri must be gs:// or file://")
    c=json.loads(read(candidate_manifest_uri));d=c.get("document",{});g=d.get("governance",{});f=[];domains={"SKT":["tworld.co.kr"],"KT":["kt.com"],"LG U+":["lguplus.com"],"신한카드 Mr.Life":["shinhancard.com"],"KB국민 톡톡 Pay카드":["kbcard.com"],"현대카드 M":["hyundaicard.com"]};u=urlparse(d.get("sourceURL","") or "");h=u.hostname or ""
    if c.get("schemaVersion")!=1:f.append("schemaVersion must be 1")
    for key in ("sourceSnapshotHash","curatedContentHash"):
        if not isinstance(c.get(key),str) or not re.fullmatch(r"[0-9a-f]{64}",c[key]):f.append(key+" must be SHA-256")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-_]{0,127}",str(d.get("id",""))):f.append("document.id must be stable ASCII")
    if u.scheme!="https" or not any(h==x or h.endswith("."+x) for x in domains.get(d.get("provider"),[])):f.append("sourceURL is not official")
    if not isinstance(d.get("content"),str) or len(d["content"].strip())<60:f.append("content must be at least 60 characters")
    if g.get("status") not in ("draft","reviewed"):f.append("candidate lifecycle must be draft or reviewed")
    if not isinstance(g.get("version"),str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",g["version"]):f.append("immutable governance.version required")
    if not isinstance(g.get("reviewer"),str) or not g["reviewer"].strip():f.append("reviewer required")
    if not isinstance(g.get("license"),str) or not g["license"].strip() or re.search(r"unknown|pending|unreviewed|미확인|검토\s*중|미정",g["license"],re.I):f.append("reviewed usage rights required")
    try: stale=date.fromisoformat(g["staleAfter"]);checked=date.fromisoformat(g["checkedAt"]);assert checked<=date.today() and stale>=checked and stale>=date.today()
    except Exception:f.append("checkedAt/staleAfter must be valid and current")
    r={"gate":"benefit_rag","candidateManifestURI":candidate_manifest_uri,"decision":"blocked" if f else "manual-review-required","findings":f,"quality":{"contentChars":len(str(d.get("content","")).strip()),"hasCalculatorRule":isinstance(d.get("rule"),dict)},"publish":{"automatic":False,"activePromotion":False,"requiredAction":"independent approve:benefit"}};open(report_path,"w").write(json.dumps(r));open(decision_path,"w").write(r["decision"])

@dsl.component(base_image="python:3.12-slim",packages_to_install=["google-cloud-storage==3.13.1"])
def adk_release_gate(prompt_manifest_uri:str,evaluation_evidence_uri:str,report_path:dsl.OutputPath(str),decision_path:dsl.OutputPath(str))->None:
    import json,re
    from google.cloud import storage
    def read(uri):
        if uri.startswith("gs://"):
            b,n=uri[5:].split("/",1);return storage.Client().bucket(b).blob(n).download_as_text()
        if uri.startswith("file://"):return open(uri[7:],encoding="utf-8").read()
        raise ValueError("artifact URI must be gs:// or file://")
    m=json.loads(read(prompt_manifest_uri));e=json.loads(read(evaluation_evidence_uri));f=[];names=set();expected={"store_context_agent","coupon_understanding_agent","benefit_retrieval_agent","personalization_agent","recommendation_agent"};entries=m.get("agents",[]) if isinstance(m.get("agents"),list) else []
    if m.get("schemaVersion")!=1:f.append("prompt manifest schemaVersion must be 1")
    if len(entries)!=5:f.append("exactly five prompt entries required")
    for i in entries:
        names.add(i.get("name"));d=i.get("sha256","");v=i.get("version","")
        if not re.fullmatch(r"[0-9a-f]{64}",d) or not v.endswith("+sha256:"+d[:12]):f.append("prompt version/hash mismatch")
    if names!=expected:f.append("prompt manifest needs exact five-agent workflow names")
    b=e.get("backendDeterministicTests",{});p=e.get("protectedAdkEval",{})
    if b.get("passed") is not True and p.get("passed") is not True:f.append("passing backend test or protected ADK eval evidence required")
    r={"gate":"adk_release","decision":"blocked" if f else "manual-release-required","findings":f,"metrics":{"backendDeterministicTests":b,"protectedAdkEval":p},"promotion":{"automatic":False,"trafficPromotion":False,"requiredAction":"human approver review"}};open(report_path,"w").write(json.dumps(r));open(decision_path,"w").write(r["decision"])

@dsl.pipeline(name="couponcok-governance-gates")
def couponcok_governance_gates(pipeline_mode:str="benefit_rag",candidate_manifest_uri:str="",prompt_manifest_uri:str="",evaluation_evidence_uri:str="",prompt_version:str="manifest",rag_version:str="candidate",model_version:str="gemini-2.5-flash")->None:
    with dsl.If(pipeline_mode=="benefit_rag"):benefit_rag_gate(candidate_manifest_uri=candidate_manifest_uri)
    with dsl.Else():adk_release_gate(prompt_manifest_uri=prompt_manifest_uri,evaluation_evidence_uri=evaluation_evidence_uri)
