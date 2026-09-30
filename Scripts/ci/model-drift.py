#!/usr/bin/env python3
"""Compare fresh model recordings with the committed ones; report drift.

Signals: a final call truncated at our budget, reasoning above 60% of the
budget, JSON purposes that no longer parse, and p95 latency doubling. Drift
is reported (Markdown + $GITHUB_OUTPUT), never a failing exit code.
"""
import argparse
import json
import os
from pathlib import Path

JSON_PURPOSES = {"digestFocus", "digestAggregate", "notes"}
REASONING_SHARE = 0.6


def load(root):
    result = {}
    for path in sorted(Path(root).glob("*/*.json")):
        data = json.loads(path.read_text())
        result[(data["model"], data["caseName"])] = data
    return result


def p95(values):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(0.95 * (len(ordered) - 1))))]


def parses(content):
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`").removeprefix("json").strip()
    try:
        json.loads(text)
        return True
    except ValueError:
        return False


def compare(committed_root, fresh_root):
    committed, fresh = load(committed_root), load(fresh_root)
    messages = []
    for key, recording in fresh.items():
        model, case = key
        calls = recording["calls"]
        for index, call in enumerate(calls):
            label = f"{model} {case} call {index + 1} ({call['purpose']})"
            is_last_of_purpose = all(later["purpose"] != call["purpose"] for later in calls[index + 1:])
            if call["finishReason"] == "length" and is_last_of_purpose:
                messages.append(f"{label}: truncated even after our retry budget")
            budget = call.get("maxTokens") or 0
            if budget and (call.get("reasoningTokens") or 0) > REASONING_SHARE * budget:
                messages.append(f"{label}: reasoning used {call['reasoningTokens']} of {budget} tokens")
            if call["purpose"] in JSON_PURPOSES and call["finishReason"] != "length" and not parses(call["content"]):
                messages.append(f"{label}: response is not valid JSON")
        if key in committed:
            old = p95([c["latencyMilliseconds"] for c in committed[key]["calls"]])
            new = p95([c["latencyMilliseconds"] for c in calls])
            if old and new > 2 * old:
                messages.append(f"{model} {case}: p95 latency {new} ms vs {old} ms committed")
    return messages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("committed")
    parser.add_argument("fresh")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    messages = compare(Path(args.committed), Path(args.fresh))
    lines = ["# Model drift", ""] + ([f"- {m}" for m in messages] or ["No drift detected."])
    Path(args.report).write_text("\n".join(lines) + "\n")
    if target := os.environ.get("GITHUB_OUTPUT"):
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(f"drift={'true' if messages else 'false'}\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
