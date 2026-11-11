import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class HourlyRaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.migration = (
            ROOT / "supabase" / "migrations" / "202611110008_next_hourly_race.sql"
        ).read_text(encoding="utf-8")
        cls.page = (ROOT / "collection.html").read_text(encoding="utf-8")

    def test_schedule_exposes_current_and_upcoming_races(self):
        self.assertIn("race_slot_start timestamptz", self.migration)
        self.assertIn(
            "generate_series(v_current_slot, v_next_slot, interval '1 hour')",
            self.migration,
        )
        self.assertIn(
            "where races.slot_start in (v_current_slot, v_next_slot)",
            self.migration,
        )

    def test_registration_is_limited_to_upcoming_race_and_closes_early(self):
        self.assertIn("p_slot_start is distinct from v_next_slot", self.migration)
        self.assertIn("now() >= p_slot_start - interval '5 minutes'", self.migration)
        self.assertIn("now() < p_slot_start - interval '1 hour'", self.migration)
        self.assertIn("race_slot_start || race.slot_start", self.page)
        self.assertIn("now < start - 60 * 60_000", self.page)
        self.assertIn("now < start - 5 * 60_000", self.page)


if __name__ == "__main__":
    unittest.main()
