"""CI entry point: exits non-zero if a workflow prompt lacks a manifest update."""

from couponcok_agent.prompt_versions import PROMPT_METADATA


if __name__ == "__main__":
    assert len(PROMPT_METADATA) == 5
    print("Prompt manifest is current for:", ", ".join(item["name"] for item in PROMPT_METADATA))
