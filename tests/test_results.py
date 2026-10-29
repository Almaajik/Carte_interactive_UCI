import unittest
from unittest.mock import Mock, patch

import results


def result_table(rider):
    return (
        '<table class="wikitable"><tr><th>Rank</th><th>Rider</th></tr>'
        + "".join(f"<tr><td>{rank}</td><td>{rider} {rank}</td></tr>" for rank in range(1, 4))
        + "</table>"
    )


class ResultsTests(unittest.TestCase):
    def test_wiki_title_prefers_womens_edition(self):
        response = Mock()
        response.json.return_value = {
            "query": {
                "search": [
                    {"title": "2026 Cadel Evans Great Ocean Road Race"},
                    {"title": "2026 Cadel Evans Great Ocean Road Race (women's race)"},
                ]
            }
        }
        with patch.object(results.requests, "get", return_value=response) as get:
            title = results.wiki_title("Cadel Evans Great Ocean Road Race", "2026", women_race=True)

        self.assertIn("women", title.lower())
        self.assertIn("women", get.call_args.kwargs["params"]["srsearch"].lower())

    def test_parser_selects_womens_table(self):
        html = (
            "<h2>Men's race</h2>" + result_table("Men Rider")
            + "<h2>Women's race</h2>" + result_table("Women Rider")
        )

        parsed = results.parse_results(html, stage_race=False, women_race=True)

        self.assertEqual("Women Rider 1", parsed["rows"][0]["rider"])

    def test_parser_rejects_unmarked_mens_page_for_womens_race(self):
        parsed = results.parse_results(result_table("Men Rider"), stage_race=False, women_race=True)

        self.assertIsNone(parsed)

    def test_detects_womens_uci_class(self):
        self.assertTrue(results.is_womens_race({"name": "Cadel Evans Great Ocean Road Race", "classes": ["1.WWT"]}))

    def test_detects_womens_race_names_in_multiple_languages(self):
        for name in ("Tour Down Under Women's Race", "Vuelta CV Feminas", "Vuelta a Extremadura Femenina", "Volta Feminina"):
            with self.subTest(name=name):
                self.assertTrue(results.is_womens_race({"name": name, "classes": ["1.Pro"]}))


if __name__ == "__main__":
    unittest.main()