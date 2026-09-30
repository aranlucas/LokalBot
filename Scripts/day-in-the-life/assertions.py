#!/usr/bin/env python3
"""User-visible assertions for the day-in-the-life run."""
import json
from pathlib import Path
import sys


def health_problems(report):
    problems = []
    for finding in report["findings"]:
        if finding["status"] == "fail":
            problems.append(f"health {finding['check']} failed: {finding.get('summary', '')}")
        if finding["check"] == "digestCoverage":
            coverage = finding.get("measurements", {}).get("coverage", 0)
            if coverage < 0.6:
                problems.append(f"digest covers only {coverage:.0%} of tracked activity")
    return problems


def has_action_owned_by_me(folder):
    data = json.loads((Path(folder) / "outcomes.json").read_text())
    return any(action.get("isForUser") is True or str(action.get("owner", "")).lower() == "me"
               for action in data.get("actionItems", []))


if __name__ == "__main__":
    mode, target = sys.argv[1], sys.argv[2]
    if mode == "health":
        problems = health_problems(json.loads(Path(target).read_text()))
        print("\n".join(problems))
        sys.exit(1 if problems else 0)
    if mode == "owned-action":
        sys.exit(0 if has_action_owned_by_me(target) else 1)
