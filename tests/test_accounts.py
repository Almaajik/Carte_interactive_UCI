import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import create_app


class AccountApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = create_app({
            "TESTING": True,
            "SECRET_KEY": "test-secret-key",
            "DATABASE": str(Path(self.temp.name) / "accounts.sqlite3"),
            "SESSION_COOKIE_SECURE": False,
        })
        self.client = self.app.test_client()
        self.csrf = self.client.get("/api/session").json["csrfToken"]

    def tearDown(self):
        self.temp.cleanup()

    def register(self, username):
        response = self.client.post("/api/register", json={"username": username, "password": "correct-horse-battery"},
                                    headers={"X-CSRF-Token": self.csrf})
        if response.status_code == 201:
            self.csrf = self.client.get("/api/session").json["csrfToken"]
        return response

    def save_collection(self, payload):
        return self.client.put("/api/collection", json=payload, headers={"X-CSRF-Token": self.csrf})

    def test_collection_requires_login(self):
        self.assertEqual(401, self.client.get("/api/collection").status_code)

    def test_registration_login_and_persisted_collection(self):
        response = self.register("rider_one")
        self.assertEqual(201, response.status_code)
        self.assertEqual("rider_one", response.json["user"]["username"])

        collection = {
            "riders": {"alice-fra": {"rider": "Alice Rider", "count": 2, "rarity": "winner"}},
            "dust": 80,
            "freeDate": "2026-10-29",
            "packsOpened": 3,
            "lastPack": [],
        }
        self.assertEqual(200, self.save_collection(collection).status_code)
        self.client.post("/api/logout", headers={"X-CSRF-Token": self.csrf})
        self.csrf = self.client.get("/api/session").json["csrfToken"]
        self.assertEqual(401, self.client.get("/api/collection").status_code)

        csrf = self.client.get("/api/session").json["csrfToken"]
        login = self.client.post("/api/login", json={"username": "RIDER_ONE", "password": "correct-horse-battery"},
                                 headers={"X-CSRF-Token": csrf})
        self.assertEqual(200, login.status_code)
        self.assertEqual(collection, self.client.get("/api/collection").json["collection"])

    def test_accounts_have_isolated_collections(self):
        self.register("rider_one")
        collection = {"riders": {"alice": {"rider": "Alice", "count": 1, "rarity": "top10"}},
                      "dust": 0, "freeDate": "", "packsOpened": 1, "lastPack": []}
        self.assertEqual(200, self.save_collection(collection).status_code)
        self.client.post("/api/logout", headers={"X-CSRF-Token": self.csrf})
        self.csrf = self.client.get("/api/session").json["csrfToken"]

        csrf = self.client.get("/api/session").json["csrfToken"]
        self.assertEqual(201, self.client.post("/api/register", json={"username": "rider_two", "password": "another-correct-password"},
                                                headers={"X-CSRF-Token": csrf}).status_code)
        self.assertEqual({}, self.client.get("/api/collection").json["collection"]["riders"])

    def test_mutations_require_csrf(self):
        self.assertEqual(403, self.client.post("/api/register", json={"username": "rider_one", "password": "correct-horse-battery"}).status_code)

    def test_malformed_auth_payload_is_rejected(self):
        response = self.client.post("/api/register", json=["not", "an", "object"],
                                    headers={"X-CSRF-Token": self.csrf})
        self.assertEqual(400, response.status_code)

    def test_login_attempts_are_rate_limited(self):
        statuses = []
        for _ in range(9):
            response = self.client.post("/api/login", json={"username": "unknown", "password": "wrong-password"},
                                        headers={"X-CSRF-Token": self.csrf})
            statuses.append(response.status_code)
        self.assertEqual([401] * 8 + [429], statuses)

    def test_invalid_collection_is_rejected(self):
        self.register("rider_one")
        response = self.save_collection({"riders": [], "dust": -1, "freeDate": "", "packsOpened": 0, "lastPack": []})
        self.assertEqual(400, response.status_code)

    def test_production_requires_a_secret_key(self):
        with patch.dict("os.environ", {"APP_ENV": "production"}, clear=False):
            with patch.dict("os.environ", {}, clear=False):
                import os
                os.environ.pop("SECRET_KEY", None)
                with self.assertRaises(RuntimeError):
                    create_app({"DATABASE": str(Path(self.temp.name) / "production.sqlite3")})


if __name__ == "__main__":
    unittest.main()