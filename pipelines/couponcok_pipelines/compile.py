from __future__ import annotations

import argparse
from pathlib import Path


def compile_pipeline(output: str) -> None:
    from kfp import compiler
    from .pipeline import couponcok_governance_gates
    Path(output).parent.mkdir(parents=True, exist_ok=True)
    compiler.Compiler().compile(couponcok_governance_gates, package_path=output)


def main() -> None:
    parser = argparse.ArgumentParser(description="Compile CouponCock's offline governance KFP v2 template")
    parser.add_argument("--output", default="dist/couponcok-governance-gates.json")
    args = parser.parse_args()
    compile_pipeline(args.output)
    print(f"compiled {args.output}")


if __name__ == "__main__":
    main()
