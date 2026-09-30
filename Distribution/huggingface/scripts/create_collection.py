#!/usr/bin/env python3
"""Create or sync LokalBot's public Hugging Face model collection.

The collection mirrors the default stack: items missing from ``ITEMS`` are
removed, notes are rewritten, and positions follow the order below.
"""

from huggingface_hub import (
    HfApi,
    add_collection_item,
    create_collection,
    delete_collection_item,
    get_collection,
    update_collection_item,
    update_collection_metadata,
)
from huggingface_hub.errors import HfHubHTTPError

NAMESPACE = "stevyhacker"
TITLE = "LokalBot recommended local stack"
DESCRIPTION = (
    "LokalBot 6.8 GB default stack: transcription, diarization, summaries, "
    "search, autocomplete. Links only. https://github.com/stevyhacker/lokalbot"
)

ITEMS = [
    (
        "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
        "Default transcription. 8-bit MLX conversion of Qwen/Qwen3-ASR-1.7B (2.47 GB). Apache-2.0.",
    ),
    (
        "FluidInference/nemotron-3-diarization-coreml",
        "Default speaker diarization. Core ML offline model (0.2 GB) of nvidia/Nemotron-3-Diarization, "
        "run through FluidAudio. 14.6% DER vs 43.4% for the previous Pyannote setup on AMI. OpenMDW-1.1.",
    ),
    (
        "unsloth/Qwen3.5-4B-GGUF",
        "Default for summaries and chat. Q4_K_M (2.74 GB): a 26-minute meeting to notes in 33 s warm, "
        "about 85 tok/s decode on M4 Max. Apache-2.0.",
    ),
    (
        "mradermacher/harrier-oss-v1-0.6b-GGUF",
        "Default semantic search. Q8_0 (0.64 GB) on a dedicated llama-server with embeddings enabled. "
        "Correct passage first for 40/48 test queries vs 35/48 for Qwen3 Embedding 0.6B. MIT.",
    ),
    (
        "unsloth/LFM2.5-1.2B-Instruct-GGUF",
        "Default autocomplete. Q4_K_M (0.73 GB) of LiquidAI's model; 484 ms p95 in LokalBot's cotyping gate. "
        "LFM Open License: check revenue eligibility.",
    ),
]

VERIFICATION = {
    "aufklarer/Qwen3-ASR-1.7B-MLX-8bit": ("model.safetensors",),
    "FluidInference/nemotron-3-diarization-coreml": ("Nemotron3Diarizer_offline.mlmodelc",),
    "unsloth/Qwen3.5-4B-GGUF": ("Q4_K_M",),
    "mradermacher/harrier-oss-v1-0.6b-GGUF": ("Q8_0",),
    "LiquidAI/LFM2.5-1.2B-Instruct": (),
    "unsloth/LFM2.5-1.2B-Instruct-GGUF": ("Q4_K_M",),
}


def main() -> None:
    if len(DESCRIPTION) >= 150:
        raise RuntimeError(
            "Hugging Face Collection descriptions must be under 150 characters"
        )

    api = HfApi()
    username = api.whoami()["name"]
    if username != NAMESPACE:
        raise RuntimeError(f"Authenticated as {username!r}; expected {NAMESPACE!r}")

    for repo_id, expected_fragments in VERIFICATION.items():
        info = api.model_info(repo_id, files_metadata=False)
        filenames = [sibling.rfilename for sibling in info.siblings]
        missing = [
            fragment
            for fragment in expected_fragments
            if not any(fragment in filename for filename in filenames)
        ]
        if missing:
            raise RuntimeError(f"{repo_id} is missing expected files: {missing}")

    slug = create_collection(
        title=TITLE,
        namespace=NAMESPACE,
        description=DESCRIPTION,
        private=False,
        exists_ok=True,
    ).slug

    try:
        update_collection_metadata(slug, description=DESCRIPTION)
    except HfHubHTTPError as error:
        print(f"warning: description not updated ({error.response.status_code}); set it in the web UI")

    for repo_id, note in ITEMS:
        add_collection_item(slug, item_id=repo_id, item_type="model", note=note, exists_ok=True)

    wanted = {repo_id for repo_id, _ in ITEMS}
    for item in get_collection(slug).items:
        if item.item_id not in wanted:
            delete_collection_item(slug, item.item_object_id)

    current = {item.item_id: item for item in get_collection(slug).items}
    for position, (repo_id, note) in enumerate(ITEMS):
        update_collection_item(slug, current[repo_id].item_object_id, note=note, position=position)

    print(f"https://huggingface.co/collections/{slug}")


if __name__ == "__main__":
    main()
