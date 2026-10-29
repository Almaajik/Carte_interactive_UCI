import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path
from unittest.mock import patch

import geocode


class GeocodeTests(unittest.TestCase):
    def test_country_match_uses_exact_country_not_substring(self):
        self.assertFalse(geocode.country_matches("Niger", {"country": "Nigeria"}))
        self.assertTrue(geocode.country_matches("Spain", {"country": "Spain"}))
        self.assertTrue(geocode.country_matches("Czechia", {"country": "Czech Republic"}))
        self.assertTrue(geocode.country_matches("Spain", {"display": "Somewhere, Spain"}))

    def test_fresh_negative_cache_avoids_request(self):
        cache = {"query": {geocode.NEGATIVE_CACHE_KEY: date.today().isoformat()}}
        with patch.object(geocode, "nominatim") as nominatim, patch.object(geocode, "CACHE", Path(tempfile.gettempdir()) / "unused-geocache.json"):
            self.assertIsNone(geocode.lookup("query", cache))

        nominatim.assert_not_called()

    def test_expired_negative_cache_is_retried(self):
        old_date = (date.today() - timedelta(days=geocode.NEGATIVE_CACHE_TTL_DAYS)).isoformat()
        cache = {"query": {geocode.NEGATIVE_CACHE_KEY: old_date}}
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(geocode, "CACHE", Path(tmp) / "geocache.json"), \
             patch.object(geocode, "nominatim", return_value={"lat": 1, "lon": 2}), \
             patch.object(geocode.time, "sleep"):
            result = geocode.lookup("query", cache)

        self.assertEqual({"lat": 1, "lon": 2}, result)
        self.assertEqual(result, cache["query"])

    def test_legacy_null_cache_entry_is_migrated_without_request(self):
        cache = {"query": None}
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(geocode, "CACHE", Path(tmp) / "geocache.json"), \
             patch.object(geocode, "nominatim") as nominatim:
            self.assertIsNone(geocode.lookup("query", cache))

        nominatim.assert_not_called()
        self.assertIn(geocode.NEGATIVE_CACHE_KEY, cache["query"])


if __name__ == "__main__":
    unittest.main()