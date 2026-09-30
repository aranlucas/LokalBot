# LokalBot local-stack benchmarks — extracted numbers

Every number below is copied verbatim from a file in this repository; the **Source** column or line is the path to check. Nothing here is estimated or invented. All measurements to date were taken on a single machine: an **Apple M4 Max, 48 GB** of unified memory. These are engine-level benchmarks, not end-to-end UI timings. The repository index of every report is `Benchmarks/README.md`.

## Current default stack

The defaults on a fresh install total about **6.8 GB** of model files if every role is used (`README.md`, "Local AI, your choice").

| Role | Default model | Format | Model files | Headline result | Source |
| --- | --- | --- | ---: | --- | --- |
| Transcription | Qwen3-ASR 1.7B | MLX 8-bit | 2.47 GB | Not yet measured (see gaps) | `README.md` |
| Speaker diarization | Nemotron 3 (preview) via FluidAudio | Core ML | ~0.20 GB | 14.56% DER vs 43.44% for the previous default; 500× real time | `Benchmarks/NemotronDiarization/results/2026-09-23/REPORT.md` |
| Summaries and chat | Qwen3.5 4B | `Q4_K_M` | 2.74 GB | 26-minute meeting summarized in 33.4 s warm / 59.8 s cold | `Benchmarks/SummaryEfficiency/results-2026-09-09.json` |
| Semantic search | Harrier OSS v1 0.6B | `Q8_0` | 0.64 GB | Correct passage first for 40/48 queries vs 35/48 for Qwen3 Embedding 0.6B | `Benchmarks/ModelAlternatives/2026-09-07/REPORT.md` |
| Autocomplete | LFM2.5 1.2B Instruct | `Q4_K_M` | 0.73 GB | 28/28 safety, 12/13 completions, 484–494 ms p95 | `Benchmarks/Cotyping/results/2026-07-21-model-debounce-benchmark.md` |
| Screen text (opt-in) | Apple Vision | Built into macOS | — | 0.971 token F1 at 119.6 ms per synthetic screenshot | `Benchmarks/OCR/SYNTHETIC-RESULTS-2026-06-24.md` |

Alternatives remain selectable in the app: Parakeet, Granite Speech, Whisper large-v3 turbo, SenseVoice, and GigaAM for transcription, and Pyannote Community-1 for diarization (`README.md`).

## Speaker diarization — Nemotron 3 vs Pyannote Community-1

Four independent English AMI test meetings, each evaluated as headset mix and distant-microphone audio: **8 conditions, 184.55 minutes of audio**, four speakers in every reference. DER adds missed speech, false alarms, and speaker confusion, divided by reference speaker time; overlap is scored and no speaker-count hints were used. Speed is the warm median over three runs on the 17.49-minute ES2004a headset recording. Source: `Benchmarks/NemotronDiarization/results/2026-09-23/REPORT.md` (scores in `Benchmarks/NemotronDiarization/results/2026-09-23/scores.json`).

| System | DER, zero collar | DER, 250 ms collar | Correct speaker count | Audio / processing time | Peak process RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pyannote Community-1 via FluidAudio (previous LokalBot default) | 43.44% | 30.45% | 5/8 | 243× | 0.68 GiB |
| FluidAudio community defaults + overlap | 43.61% | 30.44% | 5/8 | — | 0.66 GiB |
| **Nemotron 3 offline, full-precision Core ML (current default)** | **14.56%** | **8.34%** | **8/8** | **500×** | 0.67 GiB |
| Nemotron 3 fast128 | 14.51% | 8.19% | 8/8 | 365× | 0.64 GiB |
| Nemotron 3 c128 W8A8 (CPU/ANE) | 15.73% | 9.34% | 7/8 | 480× | 0.63 GiB |

The offline model reduced speaker confusion from **8.87% to 1.77%**, missed speech from **15.34% to 8.40%**, and false alarms from **19.23% to 4.38%** (percentage points of reference speaker time), and beat the baseline on all eight conditions. The report's caveat applies: this is a comparison against the pinned FluidAudio implementation and its configurations, not a claim about every implementation of Pyannote Community-1. It does not cover more than four speakers, other languages, or end-to-end name attribution.

## Summaries and action items — Qwen3.5 4B

Replay of LokalBot's production summary and action extractor with `Qwen3.5-4B-Q4_K_M.gguf` on llama.cpp **b10173**. Cold includes runtime startup; warm reuses the loaded runtime. ASR time is excluded. Source: `Benchmarks/SummaryEfficiency/results-2026-09-09.json`.

| Meeting | Transcript | Cold | Warm | Outcome |
| --- | ---: | ---: | ---: | --- |
| 26-minute meeting | 4,477 words | 59.8 s | 33.4 s | Complete |
| 91-minute meeting | 11,229 words | 71.5 s | 74.2 s | Complete |

Decode speed across these runs was about 85 tokens/s (`Benchmarks/README.md`). These are timings, not a summary-quality score.

In the 2026-09-07 pilot, MiniCPM5-2B `Q4_K_M` was smaller (1.561 GB vs 2.741 GB) and faster on long context (18.68 s vs 32.41 s), but it looped on one summary and misattributed action items, so Qwen3.5 4B remains the default (`Benchmarks/ModelAlternatives/2026-09-07/REPORT.md`).

## Semantic search — Harrier vs Qwen3 Embedding

48 authored queries (24 English, 24 Serbian/Montenegrin in Latin and Cyrillic) against a 110-document corpus; relevant passage IDs fixed before inference. Both models used Q8 weights, 1,024 dimensions, and the app's query/document prefixes. Source: `Benchmarks/ModelAlternatives/2026-09-07/REPORT.md`.

| Measure | Qwen3 Embedding 0.6B Q8 (previous default) | Harrier 0.6B Q8 (current default) |
| --- | ---: | ---: |
| Correct passage ranked first | 35/48 (72.9%) | **40/48 (83.3%)** |
| Correct passage in top five | 45/48 (93.8%) | **47/48 (97.9%)** |
| English top one | 22/24 | 22/24 |
| Serbian/Montenegrin top one | 13/24 | **18/24** |
| Mean reciprocal rank | 0.814 | **0.903** |
| Repeated query latency, median | 11.85 ms | 11.97 ms |

The gain came from the Serbian/Montenegrin queries; English tied. 48 correlated, authored queries make this a pilot, not a general retrieval benchmark.

## Speech recognition — Granite Speech 4.1 vs Granite Speech 5

44 public clips / 271.3 seconds (24 conversational AMI clips, 20 clean LibriSpeech clips), scored with the standard Whisper English normalizer. Source: `Benchmarks/ModelAlternatives/2026-09-07/REPORT.md`. **Qwen3-ASR 1.7B, the current default, was not part of this run.**

| Measure | Granite 4.1 Q4 | Granite 4.1 Q8 | Granite 5 TurboCTC BF16 |
| --- | ---: | ---: | ---: |
| Normalized word-error rate | 4.42% (35/791) | 4.93% (39/791) | 5.18% (41/791) |
| AMI normalized WER | 8.83% | 9.09% | 10.13% |
| LibriSpeech normalized WER | 0.25% | 0.99% | 0.49% |
| Audio seconds processed per second | 33.2× | 29.3× | **280.2×** |
| Median clip latency | 161 ms | 187 ms | **17.5 ms** |
| Sampled peak process RSS | 2.87 GiB | 3.62 GiB | 1.05 GiB |

Granite 5 is English-only, emits unpunctuated lowercase text, and is not integrated into LokalBot. This small set does not establish a reliable accuracy ordering.

## Cotyping (inline autocomplete) latency matrix

Harness: production `LokalBot --cotyping-bench`, all 28 default scenarios through the real in-process llama.cpp engine. Gate = 28/28 safety, ≥12/13 word completions, p95 ≤ 2000 ms. Source: `Benchmarks/Cotyping/results/2026-07-21-model-debounce-benchmark.md`.

| Model | Exact file | Bytes | Safety | Word completions | Avg latency | p95 latency | Gate |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| LFM2.5 1.2B Instruct | `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` | 730,895,584 | 28/28 | 12/13 | 143 / 143 / 151 ms (3 warmed runs) | 484 / 487 / 494 ms | Pass ×3 |
| Gemma 4 E4B Instruct | `gemma-4-E4B-it-UD-Q5_K_XL.gguf` | 6,656,152,736 | 28/28 | 12/13 | 399 ms | 1,830 ms | Pass |
| Qwen3.5 2B | `Qwen3.5-2B-Q4_K_M.gguf` | 1,280,835,840 | 27/28 | 11/13 | 437 ms | 1,629 ms | Fail quality |
| Qwen3.5 4B | `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 | 27/28 | 11/13 | 434 ms | 1,652 ms | Fail quality |
| Gemma 4 E2B (base) | `gemma-4-E2B.i1-Q6_K.gguf` | 3,845,328,608 | 26/28 | 10/13 | 883 ms | 2,560 ms | Fail quality + latency |
| Gemma 4 E4B (base) | `gemma-4-E4B-UD-Q5_K_XL.gguf` | 6,700,259,616 | 26/28 | 10/13 | 697 ms | 3,022 ms | Fail quality + latency |

Supporting figures from the same sources:

- LFM2.5 keyword relevance: **15/64 hits vs 13/64** for the Gemma instruct baseline — "a weak relevance signal, not a separate gate" (`Benchmarks/Cotyping/results/2026-07-21-model-debounce-benchmark.md`).
- Cold Metal-kernel compilation, first scenario only: LFM2.5 **19,349 ms**, Gemma E4B instruct **127,466 ms** (same file).
- Debounce replay on LFM warmed runs: in-process debounce **35 / 55 ms** avg/p95; inferred end-to-end **178–186 / 509–519 ms** avg/p95 (same file; arithmetic replay, not a typing trace).
- Earlier engine bench (2026-07-06): Gemma E4B instruct avg **459 ms**, p95 **1798 ms**, steady-state **~200 ms**; the base variant measured avg **564 ms**, p95 **2393 ms** (`Benchmarks/Cotyping/results/2026-07-06-cotypist-parity.md`; raw JSON siblings `2026-07-06-engine-bench.json`, `2026-07-06-engine-bench-base-model.json`). A later side-by-side run logged avg **471 ms** / p95 **1798 ms** (`Benchmarks/Cotyping/results/20260706-165057-cotypist-vs-lokalbot.md`; its GUI capture leg recorded no insertions and is not usable as data).

## Screenshot OCR — real stored screenshots

Input: 15 real LokalBot screenshots exported from the encrypted local store; Apple Vision baseline min 140.8 ms / max 404.8 ms. Hardware: M4 Max. Source: `Benchmarks/OCR/RESULTS-2026-06-24.md`. "Overlap" = token overlap vs Apple Vision output.

| Engine | Images | Mean latency | Token overlap vs Vision | Verdict in source |
| --- | ---: | ---: | ---: | --- |
| Apple Vision `VNRecognizeTextRequest` | 15 | 243.2 ms | — | Current LokalBot baseline |
| PP-OCRv5 mobile det+rec | 5 | 18.46 s | 0.187 | Too slow |
| PP-OCRv5 server det+rec | 5 | 15.32 s | 0.147 | Too slow |
| PP-OCRv6 medium det+rec | 5 | 22.43 s | 0.208 | Too slow |
| TrOCR small printed | 3 | 2.47 s | 0.001 | Line-level; not a screenshot replacement |
| GOT-OCR 2.0 (HF, MPS, 256-token cap) | 3 | 3.70 s | 0.000 | Poor screenshot output |
| GLM-OCR (MPS, 256-token cap) | 3 | 5.74 s | 0.127 | Too slow/partial |
| PaddleOCR-VL 1.6 GGUF (256-token cap) | 3 | 1.30 s | 0.027 | Fast but heavily truncated |
| PaddleOCR-VL 1.6 GGUF (1024-token cap) | 3 | 2.74 s | 0.104 | Best non-Vision runtime, still slower and partial |
| DeepSeek-OCR GGUF (512-token cap) | 3 | 1.64 s | 0.000 | Hallucinated unrelated content |

## Screenshot OCR — synthetic set with ground truth

Input: 5 generated screenshots with ground-truth text (`Benchmarks/OCR/synthetic/manifest.tsv`). Metric: normalized multiset token scores; char similarity is reading-order sensitive. Hardware: M4 Max. Source: `Benchmarks/OCR/SYNTHETIC-RESULTS-2026-06-24.md`.

| Engine | Mean latency | Token precision | Token recall | Token F1 | Char similarity |
| --- | ---: | ---: | ---: | ---: | ---: |
| Apple Vision | 119.6 ms | 0.971 | 0.971 | 0.971 | 0.812 |
| PP-OCRv6 medium | 6.78 s | 0.960 | 0.990 | 0.974 | 0.867 |
| PaddleOCR-VL GGUF | 1.70 s | 0.871 | 0.813 | 0.777 | 0.731 |
| DeepSeek-OCR GGUF | 1.44 s | 0.844 | 0.732 | 0.741 | 0.680 |

Notes from the same file: PP-OCRv6 was the only open-source option slightly above Apple Vision on quality but **~57× slower** with a **~15 s model load**; a DeepSeek-OCR rerun with the upstream-style `Free OCR.` prompt fell to mean token F1 **0.529**. Decision in both OCR files: keep Apple Vision as the default screenshot OCR pipeline.

## Honest gaps — what is NOT yet measured

| Gap | One-line plan |
| --- | --- |
| Single-chip coverage: every number above is one M4 Max (48 GB); no 16 GB, M1, M2, or M3 results | Re-run the summary replay, `--cotyping-bench`, and the OCR harness on M1, M2, and M3 machines before claiming per-chip guidance. |
| No word-error rate or realtime factor for Qwen3-ASR 1.7B, the default transcription model | Run it through the 44-clip set from `Benchmarks/ModelAlternatives/2026-09-07/REPORT.md` alongside Parakeet and Whisper large-v3 turbo. |
| Diarization tested only on four-speaker English AMI meetings | Add five-to-eight-speaker and non-English recordings, plus LokalBot's own mic/system-track captures. |
| Search pilot is 48 authored queries | Validate Harrier with annotated queries over a larger real library. |
| No summarization-quality evaluation for Qwen3.5 4B | Human-rate recaps on a fixed meeting corpus (faithfulness, action-item completeness); publish rubric + raw ratings. |
| OCR sets are small (15 real + 5 synthetic screenshots) | Grow the synthetic manifest to ≥50 fixtures across app categories and re-run `score_text_outputs.py`. |
| Cotyping keyword-hit count is self-declared a weak signal | Replace with a curated expected-completion suite reviewed by humans before quoting relevance numbers. |
