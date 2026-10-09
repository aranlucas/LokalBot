# README hero

The root [README](../../README.md) opens with [lokalbot-hero-light.png](lokalbot-hero-light.png)
or [lokalbot-hero-dark.png](lokalbot-hero-dark.png), whichever matches the
viewer's appearance. Each is a composite: two unedited captures of the native
SwiftUI views on a drawn background, under the tagline, with "saw" and "said"
labels beside Quick Recall's Screens and Meetings groups. Nothing inside the
captures was retouched. All content is fictional demo data, and each image
pairs a meeting with a search on a different topic.

Both were captured on **October 9, 2026** from `master` at
[`1ade074`](https://github.com/stevyhacker/lokalbot/tree/1ade074a90510866d8909dc17e2e1dde372831b7)
(0.10.2, build 46) in the isolated LokalBot UI Test Host, with a temporary
storage root and UserDefaults suite. The installed app and user library were
not used, and no UI tests were run.

| Image | Meeting window | Quick Recall |
| --- | --- | --- |
| light | "Holiday shoot planning" from `Scripts/seed_demo_library.py --profile studio` | "MacBook" in the same library |
| dark | "Customer call - Northwind" from the default demo library (`LOKALBOT_SELECT_INDEX=4`), with the Design review's demo audio copied in as its `mic.m4a` and `system.m4a` and `"speakerAliases": {"them": "Dana"}` added to its `transcript.json` | "Redis" in the same library |

Meeting windows used `LOKALBOT_CAPTURE_SIZE=1400x880` at 2×; Quick Recall used
`660x512` with `LOKALBOT_CAPTURE_SCALE=4`. The light pair came from a working
copy of the studio profile that pinned today's meetings to fixed clock times.
The committed profile anchors them to the current time, so a fresh capture
differs only in the times shown. In each image the meeting and search
captures came from one library, so their times agree.

Compose a hero from two captures (requires Google Chrome):

```bash
python3 Scripts/render_readme_hero.py --theme light --meetings meetings.png --recall quick-recall.png --out Assets/hero/lokalbot-hero-light.png
```

The script reproduces both published files pixel for pixel from their source
captures.

| File | Dimensions | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `lokalbot-hero-light.png` | 3200 × 1800 | 3,925,994 | `fcfe19d88569ef8a7e2bc5db99132ba257921efe499c6f92458abec18e484a90` |
| `lokalbot-hero-dark.png` | 3200 × 1800 | 2,843,276 | `cd06aec577fc796c5ad7f0cfbb2b4f5db1819990709be82bd858220c7d4212fa` |
