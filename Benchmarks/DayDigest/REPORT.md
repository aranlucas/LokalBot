# Day digest: more than one task per segment

Measured on 2026-10-02 on one M4 Max with 48 GB of unified memory.

## Question

The day digest asks the model for one work item per evidence segment, and a segment is about an hour of continuous activity. An hour that interleaves a code fix, a pull-request review, and an email keeps one of them, or packs two or three into one task line with a single status. Does letting a segment report its main item plus up to two other distinct items (`other_tasks`) keep more of the day?

## Setup

- **Model:** Qwen3.5 4B `Q4_K_M`, the built-in default (`Qwen3.5-4B-Q4_K_M.gguf`, SHA-256 `00fe7986ff5f6b46…`).
- **Server:** llama.cpp `llama-server` v0.5.0 from the app build, started with the app's flags: `-c 32768 -ngl 99 --jinja --cache-ram 2048 --reasoning on`, on a separate port.
- **Client:** `DayDigestOverviewGenerator.generateResult` with the app's `OpenAICompatibleEngine` (`.llamaServer` dialect, 8,192-token default thinking budget), so segment, retry, and aggregation requests are the production ones: 2,048 output tokens, 256 thinking tokens, and temperature 0.2 per segment.
- **Test set:** `cases.json`, three synthetic workdays with 9 segments and 13 known work items:
  - **parallel-morning:** 6 items, 3 in one hour, 1, then 2.
  - **focused-day:** a two-hour migration (two segments, one item) and an OKR document (one item).
  - **mixed-with-noise:** 2 items in one hour, a leisure-browsing half hour, then 3 items in one hour.
- **Runs:** 5 per condition. Baseline is the code before this change; candidate is the code after it.

## Scoring

`score.py` reads the `### Tasks` list of each digest:

- An item is **covered** when a task line contains one of its keywords.
- It has its **own line** when a line mentions it and no other item.
- A line is **packed** when it mentions two or more items, a **duplicate** when every item it mentions was already covered, and **noise** when it mentions none. Lines about the leisure session count separately as **leisure**.

## Results

| | Baseline | Candidate |
| --- | --- | --- |
| Items covered, per run (of 13) | 8, 11, 9, 11, 11 (77%) | 10, 12, 13, 12, 11 (89%) |
| Items with their own line, per run | 6, 4, 5, 4, 3 (34%) | 8, 7, 6, 9, 5 (54%) |
| Task lines per run | 7.8 | 9.6 |
| Packed lines (5 runs) | 13 | 11 |
| Duplicate lines (5 runs) | 1 | 2 |
| Noise / leisure lines (5 runs) | 1 / 2 | 0 / 1 |
| Seconds per day | 27.3 | 26.6 |

Exact one-sided permutation tests over the five run totals: p = 0.02 for items with their own line and p = 0.07 for items covered.

| Day | Baseline covered / own line | Candidate covered / own line |
| --- | --- | --- |
| parallel-morning (6 items) | 4–6 / 1–2 | 4–6 / 1–5 |
| focused-day (2 items) | 2 / 2 in every run | 1–2 / 1–2 |
| mixed-with-noise (5 items) | 2–4 / 0–2 | 4–5 / 2–5 |

## What happened

- **Baseline packs tasks.** parallel-morning always got exactly three lines, one per segment. One run's line reads "AuthRateLimiter.swift fix and PR #118 review … sent escalation email regarding Acme Corp SSO", three tasks with one status, and calls the reviewed pull request "submitted". The 1:1 preparation was missed in 5 of 5 runs and the release notes in 4 of 5.
- **The candidate uses the new slot only part of the time.** 11 of 45 segment answers filled `other_tasks` (9 with one item, 2 with two). The three-task hour got extra items in 4 of 5 runs; the two-task afternoon (design work beside an incident thread) in 1 of 5.
- **Regression: lighter activity.** The candidate returned a non-substantive answer with an empty description in 6 of 45 segment answers, against 2 in the baseline. That dropped the leisure session more often, but it also dropped the OKR document in 2 of 5 runs; the baseline kept it in all 5.
- **Time:** unchanged. Segments with other items take about 3 s longer.

## Limits

- Three synthetic days, 13 items, keyword scoring, and one model; 5 runs at temperature 0.2. Real days are noisier and longer.
- Not measured: hosted models, Apple Intelligence (which receives no schema), and real libraries.
- The candidate prompt was not tuned. A second iteration could raise `other_tasks` use and restore lighter-activity descriptions; it was not run, to keep this benchmark within its time budget.

## Reproduce

```
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' \
  -derivedDataPath .build/dd -skip-testing:LokalBotUITests build-for-testing
Benchmarks/DayDigest/run.sh <label> 5
python3 Benchmarks/DayDigest/score.py Benchmarks/DayDigest/results/<label>.json
```

`results/baseline.json` and `results/candidate.json` hold every digest and model reply; `results/scores.json` holds the scored rows.
