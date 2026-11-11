import json
import re
import unicodedata
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANUAL_OVERRIDES = {
    "tobias foss", "filippo ganna", "remco evenepoel", "tadej pogacar",
    "jonas vingegaard", "primoz roglic", "wout van aert",
    "mathieu van der poel", "mads pedersen",
}

def normalize_name(value):
    decomposed = unicodedata.normalize("NFD", value.lower())
    ascii_name = "".join(char for char in decomposed if unicodedata.category(char) != "Mn")
    return re.sub(r"[^a-z0-9]+", " ", ascii_name).strip()


class RiderSkillTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.riders = json.loads((ROOT / "data" / "rider_skills.json").read_text(encoding="utf-8"))

    def test_skills_have_rank_based_variety_and_match_the_total(self):
        self.assertEqual(582, len(self.riders))
        for skill in ("mountain", "sprint", "rouleur"):
            ratings = {rider[skill] for rider in self.riders}
            self.assertGreaterEqual(len(ratings), 20)
            self.assertGreaterEqual(min(ratings), 20)
            self.assertLessEqual(max(ratings), 100)
        for rider in self.riders:
            with self.subTest(rider=rider["rider_name"]):
                self.assertEqual(
                    rider["score"],
                    rider["mountain"] + rider["sprint"] + rider["rouleur"],
                )

    def test_non_manual_ratings_reflect_top_tens_podiums_and_wins(self):
        for rider in self.riders:
            if normalize_name(rider["rider_name"]) in MANUAL_OVERRIDES:
                continue
            for skill in ("mountain", "sprint", "rouleur"):
                evidence = rider["specialtyResults"][skill]
                expected = min(
                    100,
                    20 + evidence["top10"] * 3 + evidence["podiums"] * 4 + evidence["wins"] * 6,
                )
                with self.subTest(rider=rider["rider_name"], skill=skill):
                    self.assertEqual(expected, rider[skill])


if __name__ == "__main__":
    unittest.main()
