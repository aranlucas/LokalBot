"""Keep the interface translation tables aligned and format-safe."""

import json
from pathlib import Path
import re
import unittest


RESOURCES = Path(__file__).resolve().parents[2] / "LokalBot" / "Resources"


def read_strings(language):
    entries = {}
    for line in (RESOURCES / f"{language}.lproj" / "Localizable.strings").read_text().splitlines():
        if not line.strip() or line.startswith("//"):
            continue
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
        if match is None:
            raise ValueError(f"Invalid translation entry: {line}")
        key, value = map(json.loads, match.groups())
        if key in entries:
            raise ValueError(f"Duplicate translation key: {key}")
        entries[key] = value
    return entries


class LocalizationTests(unittest.TestCase):
    def test_languages_have_matching_nonempty_entries(self):
        english = read_strings("en")
        chinese = read_strings("zh-Hans")
        self.assertEqual(english.keys(), chinese.keys())
        self.assertTrue(all(chinese.values()))
        self.assertEqual(chinese["App language"], "界面语言")
        # English must be available even when the Mac's language is Chinese.
        self.assertEqual(english["Settings"], "Settings")

    def test_format_arguments_survive_translation(self):
        english = read_strings("en")
        chinese = read_strings("zh-Hans")
        placeholders = re.compile(r"%(?:\d+\$)?(?:lld|ld|[diufgs@%])")
        for key, source in english.items():
            with self.subTest(key=key):
                self.assertEqual(placeholders.findall(source), placeholders.findall(chinese[key]))


if __name__ == "__main__":
    unittest.main()
