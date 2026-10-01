#!/usr/bin/env python3
"""Compare fresh model recordings with the committed ones; report drift.

Signals: a final call truncated at our budget, reasoning above 60% of the
budget, JSON purposes that no longer parse, a JSON list the recording filled
that now comes back empty (for example notes with only actions), and a
model's p95 latency doubling. Latency pools every case of a model and needs
several calls on both sides; one slow request is provider noise, not drift.
Drift is reported (Markdown + $GITHUB_OUTPUT), never a failing exit code.
"""
import argparse
import json
import os
from pathlib import Path

JSON_PURPOSES = {"digestFocus", "digestAggregate", "notes"}
REASONING_SHARE = 0.6
MIN_LATENCY_SAMPLES = 5


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


def parsed(content):
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`").removeprefix("json").strip()
    try:
        return json.loads(text)
    except ValueError:
        return None


def parses(content):
    return parsed(content) is not None


def emptied_lists(committed, fresh):
    """Top-level lists the committed answer filled and the fresh one left empty."""
    old, new = parsed(committed), parsed(fresh)
    if not isinstance(old, dict) or not isinstance(new, dict):
        return []
    return [(key, len(value)) for key, value in old.items()
            if isinstance(value, list) and value and new.get(key) == []]


def compare(committed_root, fresh_root):
    committed, fresh = load(committed_root), load(fresh_root)
    messages = []
    latencies = {}
    for key, recording in fresh.items():
        model, case = key
        calls = recording["calls"]
        # The same purpose's nth call answers the same request in both runs.
        recorded = {}
        for call in committed[key]["calls"] if key in committed else []:
            recorded.setdefault(call["purpose"], []).append(call)
        seen = {}
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
            nth = seen.get(call["purpose"], 0)
            seen[call["purpose"]] = nth + 1
            previous = recorded.get(call["purpose"], [])
            if call["purpose"] in JSON_PURPOSES and nth < len(previous) and "length" not in (
                    call["finishReason"], previous[nth]["finishReason"]):
                for name, count in emptied_lists(previous[nth]["content"], call["content"]):
                    messages.append(f"{label}: `{name}` is empty; the committed answer had {count}")
        if key in committed:
            old, new = latencies.setdefault(model, ([], []))
            old.extend(c["latencyMilliseconds"] for c in committed[key]["calls"])
            new.extend(c["latencyMilliseconds"] for c in calls)
    for model, (old, new) in latencies.items():
        if min(len(old), len(new)) < MIN_LATENCY_SAMPLES:
            continue
        before, after = p95(old), p95(new)
        if before and after > 2 * before:
            messages.append(f"{model}: p95 latency {after} ms vs {before} ms committed across {len(new)} calls")
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
