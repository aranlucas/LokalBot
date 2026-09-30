"""Model drift is reported, never fatal, and each signal is detected."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("drift", SOURCE / "Scripts/ci/model-drift.py")
drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drift)


def call(purpose="digestFocus", content='{"a":1}', finish="stop", max_tokens=2048, reasoning=100, latency=1000):
    return {"purpose": purpose, "maxTokens": max_tokens, "content": content, "finishReason": finish,
            "completionTokens": reasoning + 50, "reasoningTokens": reasoning, "latencyMilliseconds": latency}


class ModelDriftTests(unittest.TestCase):
    def write(self, root, model, case, calls):
        folder = Path(root) / model.replace("/", "__")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{case}.json").write_text(json.dumps(
            {"model": model, "caseName": case, "recordedAt": "2026-09-30T03:00:00Z", "calls": calls}))

    def test_clean_run_has_no_drift(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "digest-day", [call()])
            self.write(new, "m/x", "digest-day", [call()])
            self.assertEqual(drift.compare(Path(old), Path(new)), [])

    def test_each_signal_is_reported(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(old, "m/x", "digest-day", [call(latency=1000)])
            self.write(new, "m/x", "digest-day", [
                call(reasoning=1500), call(content="not json"), call(latency=5000), call(finish="length")])
            messages = " ".join(drift.compare(Path(old), Path(new)))
            self.assertIn("truncated", messages)
            self.assertIn("reasoning", messages)
            self.assertIn("not valid JSON", messages)
            self.assertIn("latency", messages)

    def test_missing_committed_recording_is_a_bootstrap_not_drift(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            self.write(new, "m/x", "digest-day", [call()])
            self.assertEqual(drift.compare(Path(old), Path(new)), [])


if __name__ == "__main__":
    unittest.main()
