#!/usr/bin/env python3
"""Paired native autocomplete replay with synthetic saved facts enabled/disabled.

Measures recall of explicitly supplied facts, not unseen-fact prediction or user
acceptance. Reference answers and case labels never enter the replay request.
"""

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import uuid

from quality_replay import digest, fold, predicted_words


def replay_input(corpus, cases, enabled):
    allowed = {"id", "prefix", "trailing", "appName", "bundleID", "windowTitle", "placeholder"}
    return {
        "cases": [{key: value for key, value in case.items() if key in allowed} for case in cases],
        "memoryItems": corpus["memoryItems"], "memoryNow": corpus["asOf"],
        "useMeetingMemory": enabled, "useScreenMemory": False,
    }


def score(cases, without, with_memory):
    ids = [case["id"] for case in cases]
    if any([row["id"] for row in observations] != ids for observations in [without, with_memory]):
        raise ValueError("Incomplete, duplicated or reordered replay")
    if any(row.get("usedPromptOverride") for row in without + with_memory):
        raise ValueError("Memory evaluation requires production prompts")
    rows = []
    for case, off, on in zip(cases, without, with_memory):
        expected = case.get("expected")
        correct = lambda observation: (not observation.get("error") and expected is not None
                                      and predicted_words(observation["text"])[:1] == [fold(expected)])
        rows.append({"id": case["id"], "kind": case["kind"], "expected": expected,
                     "offText": off["text"], "onText": on["text"],
                     "offCorrect": correct(off), "onCorrect": correct(on),
                     "memoryIDs": on.get("memoryIDs", []),
                     "selectionCorrect": on.get("memoryIDs", []) == [case["expectedMemoryID"]]
                     if expected is not None else not on.get("memoryIDs", []),
                     "unchanged": off["text"] == on["text"] and off["prompt"] == on["prompt"],
                     "error": off.get("error") or on.get("error"),
                     "offLatencyMs": off["latencyMs"], "onLatencyMs": on["latencyMs"]})
    relevant = [row for row in rows if row["kind"] == "relevant"]
    controls = [row for row in rows if row["kind"] == "irrelevant"]
    return {"summary": {
        "relevantCases": len(relevant), "offCorrect": sum(row["offCorrect"] for row in relevant),
        "onCorrect": sum(row["onCorrect"] for row in relevant),
        "exactSelections": sum(row["selectionCorrect"] for row in rows), "totalCases": len(rows),
        "controlCases": len(controls), "unchangedControls": sum(row["unchanged"] for row in controls),
        "errors": sum(bool(row["error"]) for row in rows),
        "offMedianMs": statistics.median(row["offLatencyMs"] for row in rows),
        "onMedianMs": statistics.median(row["onLatencyMs"] for row in rows),
    }, "cases": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="App executable, not bundle")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, default=Path(__file__).with_name("memory-cases.json"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--split", choices=["development", "heldout"], required=True)
    args = parser.parse_args()
    corpus = json.loads(args.corpus.read_text())
    cases = [case for case in corpus["cases"] if case["split"] == args.split]
    if not cases or len({case["id"] for case in cases}) != len(cases):
        raise ValueError("Empty or duplicate cases")
    app, model = args.app.resolve(strict=True), args.model.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {"appSHA256": digest(app), "modelFile": model.name, "modelSHA256": digest(model),
                "corpusSHA256": digest(args.corpus), "scriptSHA256": digest(__file__),
                "split": args.split, "caseIDs": [case["id"] for case in cases],
                "factCount": len(corpus["memoryItems"]), "settings": "production defaults",
                "context": "synthetic saved facts; no user library or learned examples",
                "metric": "first lexical word matches explicitly supplied fact"}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    observations = []
    for enabled in [False, True]:
        name = "on" if enabled else "off"
        fixture_path = args.output / f"{name}-input.json"
        fixture_path.write_text(json.dumps(replay_input(corpus, cases, enabled), ensure_ascii=False) + "\n")
        with tempfile.TemporaryDirectory(prefix="lokalbot-memory-replay-") as temp:
            root = Path(temp)
            (root / "home").mkdir()
            (root / "storage").mkdir()
            env = dict(os.environ, LOKALBOT_STORAGE_ROOT=str(root / "storage"),
                       CFFIXED_USER_HOME=str(root / "home"),
                       LOKALBOT_DEFAULTS_SUITE=f"me.dotenv.LokalBot.memory-replay.{uuid.uuid4()}")
            with (args.output / f"{name}.jsonl").open("w") as out, (args.output / f"{name}-stderr.log").open("w") as err:
                subprocess.run([str(app), "--cotyping-replay", str(fixture_path.resolve()),
                                "--model-path", str(model)], env=env, stdout=out, stderr=err,
                               timeout=900, check=True)
        observations.append([json.loads(line) for line in (args.output / f"{name}.jsonl").read_text().splitlines()])
    report = score(cases, *observations)
    report["manifest"] = manifest
    (args.output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2), flush=True)
    if report["summary"]["errors"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
