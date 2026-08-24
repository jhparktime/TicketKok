from __future__ import annotations

import argparse
import json

from .contract import pipeline_contract, validate_submission_parameters


def main() -> None:
    parser = argparse.ArgumentParser(description="Submit an offline CouponCock governance pipeline (dry-run by default)")
    parser.add_argument("--template", default="dist/couponcok-governance-gates.json")
    parser.add_argument("--project", default="REPLACE_PROJECT_ID")
    parser.add_argument("--region", default="asia-northeast3")
    parser.add_argument("--bucket", default="REPLACE_PIPELINE_BUCKET")
    parser.add_argument("--service-account", default="REPLACE_PIPELINE_SERVICE_ACCOUNT")
    parser.add_argument("--pipeline-root", default="gs://REPLACE_PIPELINE_BUCKET/couponcok/pipeline-root")
    parser.add_argument("--mode", choices=["benefit_rag", "adk_release"], default="benefit_rag")
    parser.add_argument("--prompt-version", required=True)
    parser.add_argument("--rag-version", required=True)
    parser.add_argument("--model-version", required=True)
    parser.add_argument("--candidate-manifest-uri", default="", help="gs:// candidate JSON for benefit_rag mode")
    parser.add_argument("--prompt-manifest-uri", default="", help="gs:// immutable prompt manifest for adk_release mode")
    parser.add_argument("--evaluation-evidence-uri", default="", help="gs:// backend-test or protected-ADK-eval JSON for adk_release mode")
    parser.add_argument("--submit", action="store_true", help="Actually submit; absent means dry-run")
    args = parser.parse_args()
    inputs = {"candidate_manifest_uri": args.candidate_manifest_uri, "prompt_manifest_uri": args.prompt_manifest_uri, "evaluation_evidence_uri": args.evaluation_evidence_uri}
    required = ["candidate_manifest_uri"] if args.mode == "benefit_rag" else ["prompt_manifest_uri", "evaluation_evidence_uri"]
    if args.submit and any(not inputs[key].startswith("gs://") for key in required):
        parser.error(f"{args.mode} submission requires gs:// " + ", ".join(required))
    payload = {"template_path": args.template, "project": args.project, "location": args.region, "pipeline_root": args.pipeline_root, "service_account": args.service_account, "parameter_values": {"pipeline_mode": args.mode, "prompt_version": args.prompt_version, "rag_version": args.rag_version, "model_version": args.model_version, **inputs}, "contract": pipeline_contract()}
    if not args.submit:
        print(json.dumps({"dryRun": True, **payload}, sort_keys=True))
        return
    validate_submission_parameters(project=args.project, region=args.region, bucket=args.bucket, service_account=args.service_account, pipeline_root=args.pipeline_root)
    from google.cloud import aiplatform
    aiplatform.init(project=args.project, location=args.region, staging_bucket=f"gs://{args.bucket}")
    job = aiplatform.PipelineJob(display_name=f"couponcok-{args.mode}-gate", template_path=args.template, pipeline_root=args.pipeline_root, parameter_values=payload["parameter_values"], enable_caching=False)
    job.submit(service_account=args.service_account)
    print(json.dumps({"submitted": True, "resourceName": job.resource_name}))


if __name__ == "__main__":
    main()
