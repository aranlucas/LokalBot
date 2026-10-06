# Dependency updates — 2026-10-05

The high and medium items that resolve safely are updated together. Existing
transcription models, local processing defaults and consent boundaries remain
the same. MLX has a verified upstream dependency conflict and stays pinned.

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| High | [FluidAudio](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.5) | 0.17.1 → 0.17.5 | Fixes Nemotron output-backing failures. The pinned v2 export enables the upstream M3 ANE compilation fix. ASR debug/notice text is filtered from dependency logging. |
| High | [speech-swift](https://github.com/soniqo/speech-swift/releases/tag/v0.0.28) | 0.0.26 → 0.0.28 | Qwen transcription observes cancellation at encoder/prefill/token checkpoints and throws instead of returning a cancelled partial transcript. Existing language, prompt, token and repetition policies are retained. |
| Medium | [Pi](https://github.com/earendil-works/pi/releases/tag/v1.0.3) | 0.86.1 → 1.0.3 | Updates Agent Mode's runtime and session handling. Installer/launcher use the new bundled CLI; approvals, private-library access and approved-origin restrictions remain enforced. |
| Medium | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/v0.6.0) | 0.5.0 → 0.6.0 | Updates local chat, structured output, tool calls, embeddings and autocomplete. Built from checksum-pinned source for macOS 15, with generic arm64 CPU code and bundle-relative libraries. |

## MLX compatibility hold

[speech-swift 0.0.28](https://github.com/soniqo/speech-swift/blob/v0.0.28/Package.swift)
requires MLX-LM 3.31.4, whose
[manifest](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/Package.swift)
requires MLX `0.31.4..<0.32.0`. An isolated Xcode resolution attempt with speech-swift
0.0.28 and MLX 0.32.3 fails with that exact conflict. The compatible
[0.31.6 manifest](https://github.com/ml-explore/mlx-swift/blob/0.31.6/Package.swift)
still attaches the CUDA build plugin unconditionally, retaining the repository's
headless Xcode validation blocker. Keep 0.31.4 until the speech package adopts
compatible MLX-LM/MLX versions; this PR adds no fork or plugin-validation bypass.

## Upgrade behavior

- Nemotron uses immutable revision `25a90f97f254428d4b30374b76af9c74fdee8327`,
  `monolithic/v2`, and verified hashes for every file. The first use downloads
  about 199 MB into a new revision cache. The large weights and silence embedding
  retain their previous hashes; existing voice-profile compatibility IDs stay valid.
- Agent Mode's old runtime receipt no longer matches. Its normal explicit setup
  installs the new frozen lockfile and verifies the CLI, manifests and complete
  runtime tree. Conversation files live separately from that runtime cache.
- Existing model choices and private recordings are not migrated or reprocessed.
  Pending Nemotron work gets the new revision's checkpoint identity. No new
  optional ASR/TTS model is selected automatically.

## Verification

- XcodeGen generation, pinned package resolution, app/unit-target compilation,
  strict SwiftLint, diff checks, release metadata and script syntax passed.
- 80 distinct focused app tests passed, including real cached Qwen cancellation,
  pinned Nemotron v2 inference/reset on CPU/Neural Engine, native model generation,
  streaming, cancellation, prefix reuse, runtime receipts and synthetic Pi RPC.
  Cancellation and log-privacy regressions fail when their fixes are undone.
- 20 Pi runtime checks passed against a fresh production frozen install, including
  denied/approved writes, context-edit session resume, private-library and symlink
  gating, redirect rejection, full-command approval and API-key isolation. Two
  clean installs produced identical complete-tree digests using the app's verifier.
- 104 Python script tests passed. Every Nemotron artifact was downloaded and
  hashed. llama.cpp's native runtime cache verifies macOS 15 minimums and rpaths.
- Real Qwen3.5 4B server probes passed authenticated streaming, JSON schema output,
  tool calls and recovery after disconnect. Qwen3 embeddings kept 1,024 dimensions
  and minimum cosine similarity **0.99999995** against runtime 0.5.0 on two synthetic
  inputs. LFM and Gemma autocomplete each completed three headless synthetic cases
  with zero errors.
- The optional full public AMI voice-vector comparison and Granite region replay
  were not run because their prepared fixtures are unavailable. The local Mac is
  M4 Max; affected M3/M5 hardware was not exercised locally. Hosted CI provides
  the full build/unit/UI gates, with UI tests confined to hosted/remote runners. No installation or release
  was performed.
