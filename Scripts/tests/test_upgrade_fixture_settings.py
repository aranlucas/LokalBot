import importlib.util
import json
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("settings", SOURCE / "Scripts/upgrade-fixtures/settings.py")
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class UpgradeSettingsTests(unittest.TestCase):
    def test_every_profile_approves_the_remote_server_and_schedules_work(self):
        for version in settings.VERSIONS:
            with self.subTest(version=version):
                value = json.loads(settings.profile(version))
                self.assertEqual(value["summarizerBackend"], "OpenAI-compatible server")
                self.assertIn("https://openrouter.ai", value["approvedRemoteInferenceOrigins"])
                self.assertTrue(value["dayDigestAutoEnabled"])
                self.assertTrue(value["dreamingEnabled"])

    def test_only_0_9_0_and_0_9_1_carry_the_old_automation_approval(self):
        # The separate approval for scheduled remote runs existed only in
        # 0.9.0 and 0.9.1; 0.9.2 removed it (#113).
        for version in settings.VERSIONS:
            with self.subTest(version=version):
                carried = "approvedRemoteAutomationOrigins" in json.loads(settings.profile(version))
                self.assertEqual(carried, version in {"0.9.0", "0.9.1"})

    def test_fixture_keys_are_deterministic_and_32_bytes(self):
        self.assertEqual(len(bytes.fromhex(settings.fixture_key_hex("screenshot-key"))), 32)
        self.assertEqual(settings.fixture_key_hex("chat-key"), settings.fixture_key_hex("chat-key"))

    def test_workflow_matrix_lists_every_version(self):
        workflow = (SOURCE / ".github/workflows/upgrade-fixtures.yml").read_text()
        matrix = workflow.split("version: [", 1)[1].split("]", 1)[0]
        self.assertEqual([item.strip().strip('"') for item in matrix.split(",")], settings.VERSIONS)
        default = workflow.split('default: "', 1)[1].split('"', 1)[0]
        self.assertEqual(default.split(), settings.VERSIONS)


if __name__ == "__main__":
    unittest.main()
