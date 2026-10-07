"""Pull requests that cannot affect the UI still report a passing UI gate."""
import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("relevance", SOURCE / "Scripts/ci/ui-relevance.py")
relevance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relevance)


class UIRelevanceTests(unittest.TestCase):
    def test_docs_and_web_changes_do_not_need_the_ui_suite(self):
        self.assertFalse(relevance.relevant(["README.md", "Docs/plan.md", "web/index.html"]))

    def test_app_ui_test_and_ci_changes_need_the_ui_suite(self):
        for path in ["LokalBot/AppState.swift", "LokalBotUITests/MainWindowUITests.swift",
                     "project.yml", "Scripts/ci/ui-shards.py", "Scripts/ui-tests.sh",
                     ".github/workflows/ui-tests.yml", "Scripts/fetch-llama.sh",
                     "LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]:
            with self.subTest(path=path):
                self.assertTrue(relevance.relevant([path]))

    def test_prefix_patterns_do_not_match_sibling_names(self):
        self.assertFalse(relevance.relevant(["LokalBotTests/Foo.swift"]))
        self.assertFalse(relevance.relevant(["LokalBot-notes.md"]))

    def test_size_warning_only_above_sixty_files(self):
        self.assertIsNone(relevance.size_warning([f"f{i}" for i in range(60)]))
        warning = relevance.size_warning([f"f{i}" for i in range(61)])
        self.assertTrue(warning.startswith("::warning::"))
        self.assertIn("61 files", warning)


if __name__ == "__main__":
    unittest.main()
