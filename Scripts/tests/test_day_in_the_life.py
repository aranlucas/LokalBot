import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, SOURCE / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scenario = load("scenario", "Scripts/day-in-the-life/scenario.py")
assertions = load("assertions", "Scripts/day-in-the-life/assertions.py")


class ScenarioTests(unittest.TestCase):
    def test_rules_cover_every_purpose_with_a_catch_all(self):
        rules = scenario.build(SOURCE / "LokalBotTests/Fixtures/model-recordings", "z-ai/glm-5.3-flash")
        markers = json.loads((SOURCE / "LokalBotTests/Fixtures/model-recordings/purpose-markers.json").read_text())
        catch_alls = {r["match"]["systemIncludes"] for r in rules if "nth" not in r["match"]}
        self.assertTrue({markers["digestFocus"], markers["digestAggregate"], markers["notes"]} <= catch_alls)


class AssertionTests(unittest.TestCase):
    def test_health_assertions(self):
        report = {"findings": [
            {"check": "activityClock", "status": "pass", "measurements": {}},
            {"check": "digestCoverage", "status": "pass", "measurements": {"coverage": 0.8}},
            {"check": "finishedRecordings", "status": "pass", "measurements": {}}]}
        self.assertEqual(assertions.health_problems(report), [])
        report["findings"][1]["measurements"]["coverage"] = 0.4
        self.assertTrue(assertions.health_problems(report))

    def test_owned_action(self):
        # outcomes.json as MeetingOutcomes encodes it: actionItems with the
        # resolved owner ("Me") and isForUser.
        with tempfile.TemporaryDirectory() as folder:
            outcomes = Path(folder, "outcomes.json")
            outcomes.write_text(json.dumps({"actionItems": [{"text": "Draft", "owner": "Ana", "isForUser": False}]}))
            self.assertFalse(assertions.has_action_owned_by_me(Path(folder)))
            outcomes.write_text(json.dumps({"actionItems": [{"text": "Draft", "owner": "Me", "isForUser": True}]}))
            self.assertTrue(assertions.has_action_owned_by_me(Path(folder)))


if __name__ == "__main__":
    unittest.main()
