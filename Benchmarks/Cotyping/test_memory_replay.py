import unittest

from memory_replay import replay_input, score


class MemoryReplayTests(unittest.TestCase):
    def setUp(self):
        self.case = {"id": "atlas", "prefix": "Atlas owner is ", "expected": "Priya",
                     "expectedMemoryID": "fact", "kind": "relevant", "split": "heldout"}
        self.observation = {"id": "atlas", "text": "Priya", "prompt": "draft",
                            "memoryIDs": ["fact"], "latencyMs": 10, "usedPromptOverride": False}

    def testReferencesAndLabelsDoNotReachModel(self):
        fixture = replay_input({"memoryItems": [], "asOf": "2026-10-02T12:00:00Z"}, [self.case], True)
        self.assertEqual(fixture["cases"], [{"id": "atlas", "prefix": "Atlas owner is "}])

    def testScoresExactFirstWordAndSourceSelection(self):
        off = dict(self.observation, text="Alex", memoryIDs=[])
        result = score([self.case], [off], [self.observation])["summary"]
        self.assertEqual(result["offCorrect"], 0)
        self.assertEqual(result["onCorrect"], 1)
        self.assertEqual(result["exactSelections"], 1)
        invalid = dict(self.observation, error="failed")
        self.assertEqual(score([self.case], [off], [invalid])["summary"]["onCorrect"], 0)

    def testControlsCheckPromptAsWellAsText(self):
        control = {"id": "atlas", "kind": "irrelevant"}
        off = dict(self.observation, memoryIDs=[])
        on = dict(off, prompt="unexpected context")
        result = score([control], [off], [on])["summary"]
        self.assertEqual(result["unchangedControls"], 0)
        self.assertEqual(result["exactSelections"], 1)

    def testRejectsMissingResultsAndPromptOverrides(self):
        with self.assertRaises(ValueError):
            score([self.case], [], [self.observation])
        with self.assertRaises(ValueError):
            score([self.case], [self.observation], [dict(self.observation, usedPromptOverride=True)])


if __name__ == "__main__":
    unittest.main()
