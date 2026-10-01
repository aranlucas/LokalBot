#!/usr/bin/env python3
"""User-visible assertions for the day-in-the-life run."""
import json
from pathlib import Path
import re
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


def has_finished_notes(folder):
    """Real-ASR runs: notes completed with at least one action, any owner."""
    path = Path(folder) / "outcomes.json"
    return path.exists() and bool(json.loads(path.read_text()).get("actionItems"))


def words(text):
    # Hyphens, punctuation, and case are not recognition errors.
    return re.sub(r"[^a-z0-9' ]+", " ", text.lower().replace("-", " ")).split()


def spoken_words(segments):
    return [word for segment in sorted(segments, key=lambda s: s["start"]) for word in words(segment["text"])]


def word_error_rate(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, heard in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (expected != heard)))
        previous = current
    return previous[-1] / max(1, len(reference))


def transcript_word_error_rate(folder, golden):
    """WER of a processed meeting against the golden transcripts of its tracks."""
    reference = []
    for track in sorted(Path(golden).glob("*.json")):
        reference += json.loads(track.read_text())["segments"]
    hypothesis = json.loads((Path(folder) / "transcript.json").read_text())["segments"]
    return word_error_rate(spoken_words(reference), spoken_words(hypothesis))


if __name__ == "__main__":
    mode, target = sys.argv[1], sys.argv[2]
    if mode == "health":
        problems = health_problems(json.loads(Path(target).read_text()))
        print("\n".join(problems))
        sys.exit(1 if problems else 0)
    if mode == "owned-action":
        sys.exit(0 if has_action_owned_by_me(target) else 1)
    if mode == "finished-notes":
        sys.exit(0 if has_finished_notes(target) else 1)
    if mode == "wer":
        rate = transcript_word_error_rate(target, sys.argv[3])
        print(f"{rate:.1%}")
        sys.exit(0 if rate <= float(sys.argv[4]) else 1)
