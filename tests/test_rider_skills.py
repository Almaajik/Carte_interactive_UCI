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
            for skill in ("mountain", "sprint"):
                evidence = rider["specialtyResults"][skill]
                expected = min(
                    100,
                    20 + evidence["top10"] * 3 + evidence["podiums"] * 4 + evidence["wins"] * 6,
                )
                with self.subTest(rider=rider["rider_name"], skill=skill):
                    self.assertEqual(expected, rider[skill])

    def test_rouleur_rating_includes_capped_all_rounder_bonus(self):
        rouleur_values = set()
        for rider in self.riders:
            if normalize_name(rider["rider_name"]) in MANUAL_OVERRIDES:
                continue
            results = rider["specialtyResults"]
            rouleur = results["rouleur"]
            other_top10s = results["mountain"]["top10"] + results["sprint"]["top10"]
            versatility_bonus = min(12, round(other_top10s**0.5 * 3))
            expected = min(
                100,
                20 + rouleur["top10"] * 3 + rouleur["podiums"] * 4
                + rouleur["wins"] * 6 + versatility_bonus,
            )
            with self.subTest(rider=rider["rider_name"]):
                self.assertEqual(expected, rider["rouleur"])
            rouleur_values.add(rider["rouleur"])

        self.assertGreaterEqual(len(rouleur_values), 25)
        self.assertLess(sum(rider["rouleur"] == 20 for rider in self.riders), 200)

    def test_supabase_rouleur_migration_matches_the_rider_catalogue(self):
        migration = (
            ROOT / "supabase" / "migrations" / "202611110007_rider_rouleur_variety.sql"
        ).read_text(encoding="utf-8")
        rows = re.findall(r"\('([^']+)', (\d+), (\d+), (\d+)\)", migration)
        expected = {
            rider["rider_id"]: (rider["mountain"], rider["sprint"], rider["rouleur"])
            for rider in self.riders
        }
        actual = {
            rider_id: (int(mountain), int(sprint), int(rouleur))
            for rider_id, mountain, sprint, rouleur in rows
        }
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
