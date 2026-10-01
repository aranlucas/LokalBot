# Summary quality: unfinished notes and the ownership fix

Date: 2026-10-01 · Machine: Apple M4 Max, 48 GB · Summary model: built-in Qwen3.5 4B `Q4_K_M` on the app's llama.cpp · Harness: [`../..`](../..)

## Result

Before the fix, half of the meetings' notes failed even on clean human transcripts. They ended as "FAILED — Partial notes saved (k of n parts source-linked)". With the fix, every meeting's notes finished on the first run. Summary content was unchanged within run-to-run variation, at the cost of about one extra model call per meeting.

| Transcript | Build | Notes finished | ROUGE-1 / 2 / Lsum | AMI summary sentences covered | AMI actions covered | App items supported by AMI | Model calls (mean / max) | Generation time (mean / max) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| AMI manual | before (master `4b81891`) | **6 of 12** | 0.426 / 0.104 / 0.400 | 44.4% | 15.0% | 26.5% | 4.2 / 7 | 39 s / 81 s |
| AMI manual | after (`5eb7281`) | **12 of 12** | 0.424 / 0.103 / 0.397 | 40.4% | 30.0% | 30.4% | 5.2 / 10 | 42 s / 68 s |
| Qwen3-ASR (PR #129), 14.1% WER | before | **1 of 3** | 0.388 / 0.089 / 0.359 | 29.6% | 12.5% | 34.7% | 3.3 / 6 | 30 s / 43 s |
| Qwen3-ASR (PR #129), 14.1% WER | after | **3 of 3** | 0.411 / 0.102 / 0.382 | 29.6% | 12.5% | 45.2% | 2.3 / 5 | 17 s / 27 s |

"Summarize again" also rescues notes that already failed. All 8 partial meetings from the before rows finished on one retry with the fixed build, in 7–16 s each. Before the fix, the same retry failed identically every time.

Coverage counts an AMI sentence as matched when a Harrier embedding of an app item scores at least τ = 0.768 against it. τ is the 95th percentile of best matches against a different design team's AMI summary. "App items supported" is the share of the app's bullets that match any AMI sentence. AMI's summaries are short, so most app items have nothing to match.

The before and after rows are separate model runs at temperature 0.1 without a seed, so their content scores differ by sampling as well. For scale, two runs on the same manual transcript share 70.6% of their items. Notes from the ASR transcripts kept 66–68% of the manual-transcript notes, about as much as a rerun does. At 14% WER, the transcript costs little next to run-to-run variation.

## Why notes failed

All 8 failures had the same cause. An action item's ownership was rejected as `ambiguous_ownership_evidence` or `ownership_quote_not_found`. Both targeted repairs returned the same rejection, and a part can only finish with an empty repair queue.

When a segment names two actors, `OutcomeEvidencePolicy.hasCompetingActors` rejects any quote the model offers, for example "I'll prepare the policy, and you will send the measurements". Retrying is therefore deterministic: the meeting fails the same way on every attempt.

Ownership repairs also always go first. In 3 of the 8 failing parts, rejected notes or actions were queued behind the task and never got a repair call.

Apart from the FAILED status, the partial notes had the same five sections and a similar number of bullets as finished ones.

The local library showed the same pattern: 5 of 42 real meetings (12%) had partial notes. At least 3 of those ended on these ownership rejections, with GLM 5.3 Flash and Qwen 3.8 Flash as summary models. The count reads only outcome fields and rejection codes from `notes-generation-metrics.json` and `notes.parts.partial.json`, never meeting content.

## The fix

After the ownership repairs have answered in full, a task they still can't bind stays in the notes under **Owner unclear**, the way a wrong-owner claim already does. The records queued behind it then get their own two repairs.
- **Still partial:** a truncated final repair keeps the part open, so a retry gets a larger allowance. A part missing one of the user's own commitments also stays open.
- **Ownership:** the fix never claims an owner and never substitutes another task.

## Other findings

- **Decisions are rarely recorded.** AMI's annotators list 63 decisions across the 12 meetings. From manual transcripts the app recorded 9 before the fix and 4 after, and 8–9 of the 12 meetings had no decision at all.
  - **Cause:** the prompt counts only choices "explicitly settled on" (`PromptTemplates.meetingOutcomeSemanticsRule`). The 4B model reads that as almost never on design meetings. No validator rejection involves decisions, so the model isn't proposing them.
  - **Coverage figures:** AMI writes one aggregate sentence per decision set, which makes decision coverage (0–12.5%) understate recall.
  - **Status:** decision recall is the clearest quality gap this benchmark found.
- **Action items vary between runs.** Three runs on one ES2004a ASR transcript extracted 5, 0 and 3 action items in their first pass. Single-run action counts are noisy for the 4B model.
- **Due dates can be invented.** One finished note gave a due date of `2024-01-01` that nobody said.
- **Headless runs:**
  - `--process` leaves the search embedder running after it exits; only the summary server is stopped.
  - An unsigned Dev build waits forever on a Keychain prompt when it reads speaker evidence sealed by another build. That explains every stalled `--process` run during this work. `run.sh` caps each run and sets the evidence aside before summary-only runs.

## Limits

- Twelve meetings from three design teams, all English, all summarized by the built-in 4B model. Cloud summary models weren't run here. The real-library count shows they hit the same ownership dead end.
- The ASR rows cover only the three shortest meetings.
- The before and after summaries are separate samples. The completion change is far outside sampling variation (6 of 12 and 1 of 3, against 15 of 15). The content metrics aren't.
- Per-meeting numbers are in [`results.json`](results.json). It holds scores only, no transcript or summary text.
