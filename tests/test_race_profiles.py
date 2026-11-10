import json
import unittest
from pathlib import Path

from race_profiles import generate_profiles, infer_profile


ROOT = Path(__file__).resolve().parents[1]


class RaceProfilesTests(unittest.TestCase):
    def test_calendar_has_a_valid_estimated_profile_for_every_race(self):
        races = json.loads((ROOT / "data" / "races.json").read_text(encoding="utf-8"))
        profiles = generate_profiles(races)

        self.assertEqual(len(races), len(profiles))
        for slug, profile in profiles.items():
            with self.subTest(slug=slug):
                self.assertEqual(100, profile["climb_pct"] + profile["rolling_pct"] + profile["sprint_pct"])
                self.assertEqual(4, len(profile["key_points"]))
                self.assertTrue(profile["estimated"])
                self.assertEqual(sorted(point["progress"] for point in profile["key_points"]),
                                 [20, 45, 70, 100])

    def test_time_trial_uses_rouleur_profile_without_sprint_finish(self):
        profile = infer_profile({"name": "World Championships: Men's TT", "classes": [], "start": "2026-09-20", "end": "2026-09-20"})

        self.assertEqual(0, profile["climb_pct"])
        self.assertEqual(0, profile["sprint_pct"])
        self.assertFalse(profile["sprint_finish"])
        self.assertTrue(all(point["terrain"] == "rouleur" for point in profile["key_points"]))

    def test_flat_sprint_race_allocates_sprint_weight(self):
        profile = infer_profile({"name": "Scheldeprijs", "classes": ["1.Pro"], "start": "2026-04-08", "end": "2026-04-08"})

        self.assertTrue(profile["sprint_finish"])
        self.assertEqual(20, profile["sprint_pct"])
        self.assertEqual("sprint", profile["key_points"][-1]["terrain"])
        self.assertEqual(10, profile["escape_probability"])

    def test_escape_chance_rises_with_harder_routes(self):
        routes = [
            ({"name": "Tour of Taihu Lake", "classes": ["2.1"], "start": "2026-09-12", "end": "2026-09-12"}, 10),
            ({"name": "Tour Down Under", "classes": ["2.UWT"], "start": "2026-01-20", "end": "2026-01-25"}, 30),
            ({"name": "Tour de France", "classes": ["2.UWT"], "start": "2026-07-04", "end": "2026-07-26"}, 50),
        ]

        for race, expected_probability in routes:
            with self.subTest(race=race["name"]):
                self.assertEqual(expected_probability, infer_profile(race)["escape_probability"])


if __name__ == "__main__":
    unittest.main()
