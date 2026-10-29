"""Flask API and local web server for the cycling collection."""
import hmac
import json
import os
import re
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from flask import Flask, current_app, g, jsonify, request, send_from_directory, session
from flask_login import LoginManager, UserMixin, current_user, login_required, login_user, logout_user
from werkzeug.security import check_password_hash, generate_password_hash

ROOT = Path(__file__).resolve().parent
DEFAULT_COLLECTION = {"riders": {}, "dust": 0, "freeDate": "", "packsOpened": 0, "lastPack": []}
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{3,24}$")
RARITIES = {"winner", "podium", "top10", "peloton"}
login_manager = LoginManager()


class User(UserMixin):
    def __init__(self, user_id, username):
        self.id = str(user_id)
        self.username = username


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(current_app.config["DATABASE"], timeout=10)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
    return g.db


def close_db(_error=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    db = get_db()
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE COLLATE NOCASE,
            password_hash TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS collections (
            user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            payload TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS auth_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            address TEXT NOT NULL,
            attempted_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS auth_attempts_address_time
            ON auth_attempts(address, attempted_at);
        """
    )
    db.commit()


def csrf_valid():
    token = session.get("csrf_token", "")
    supplied = request.headers.get("X-CSRF-Token", "")
    return bool(token and supplied and hmac.compare_digest(token, supplied))


def csrf_required():
    if not csrf_valid():
        return jsonify(error="Jeton de sécurité absent ou expiré."), 403
    return None


def record_auth_attempt():
    db = get_db()
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(minutes=15)).isoformat()
    address = request.remote_addr or "unknown"
    db.execute("DELETE FROM auth_attempts WHERE attempted_at <= ?", (cutoff,))
    attempts = db.execute(
        "SELECT COUNT(*) FROM auth_attempts WHERE address = ? AND attempted_at > ?",
        (address, cutoff),
    ).fetchone()[0]
    if attempts >= 8:
        return None
    db.execute("INSERT INTO auth_attempts(address, attempted_at) VALUES (?, ?)", (address, now.isoformat()))
    db.commit()
    return address


def clear_auth_attempts(address):
    db = get_db()
    db.execute("DELETE FROM auth_attempts WHERE address = ?", (address,))
    db.commit()


def validate_collection(value):
    if not isinstance(value, dict):
        return False
    riders = value.get("riders")
    if not isinstance(riders, dict) or len(riders) > 5000:
        return False
    if not isinstance(value.get("dust"), int) or isinstance(value["dust"], bool) or not 0 <= value["dust"] <= 10_000_000:
        return False
    if not isinstance(value.get("packsOpened"), int) or isinstance(value["packsOpened"], bool) or not 0 <= value["packsOpened"] <= 10_000_000:
        return False
    if not isinstance(value.get("freeDate"), str) or len(value["freeDate"]) > 10:
        return False
    last_pack = value.get("lastPack")
    if not isinstance(last_pack, list) or len(last_pack) > 5:
        return False
    for key, card in riders.items():
        if not isinstance(key, str) or len(key) > 180 or not isinstance(card, dict):
            return False
        if not isinstance(card.get("count"), int) or isinstance(card["count"], bool) or not 1 <= card["count"] <= 10_000_000:
            return False
        if card.get("rarity") not in RARITIES or not isinstance(card.get("rider"), str) or len(card["rider"]) > 160:
            return False
    try:
        return len(json.dumps(value, ensure_ascii=False)) <= 900_000
    except (TypeError, ValueError):
        return False


def collection_for(user_id):
    row = get_db().execute("SELECT payload FROM collections WHERE user_id = ?", (user_id,)).fetchone()
    return json.loads(row["payload"]) if row else DEFAULT_COLLECTION.copy()


def write_collection(user_id, payload):
    db = get_db()
    db.execute(
        """INSERT INTO collections(user_id, payload, updated_at) VALUES (?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at""",
        (user_id, json.dumps(payload, ensure_ascii=False), datetime.now(timezone.utc).isoformat()),
    )
    db.commit()


def create_app(test_config=None):
    app = Flask(__name__, instance_relative_config=True)
    production = os.environ.get("APP_ENV", "development").lower() == "production"
    secret_key = os.environ.get("SECRET_KEY")
    if production and not secret_key:
        raise RuntimeError("SECRET_KEY doit être défini en production.")
    app.config.from_mapping(
        SECRET_KEY=secret_key or secrets.token_hex(32),
        DATABASE=os.environ.get("DATABASE_PATH", os.path.join(app.instance_path, "accounts.sqlite3")),
        MAX_CONTENT_LENGTH=1_000_000,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=production,
        PERMANENT_SESSION_LIFETIME=timedelta(days=14),
    )
    if test_config:
        app.config.update(test_config)
    os.makedirs(app.instance_path, exist_ok=True)
    os.makedirs(os.path.dirname(app.config["DATABASE"]) or ".", exist_ok=True)
    login_manager.init_app(app)
    login_manager.session_protection = "strong"
    app.teardown_appcontext(close_db)

    with app.app_context():
        init_db()

    @login_manager.user_loader
    def load_user(user_id):
        row = get_db().execute("SELECT id, username FROM users WHERE id = ?", (user_id,)).fetchone()
        return User(row["id"], row["username"]) if row else None

    @login_manager.unauthorized_handler
    def unauthorized():
        return jsonify(error="Connexion requise."), 401

    @app.get("/")
    @app.get("/index.html")
    def index_page():
        return send_from_directory(ROOT, "index.html")

    @app.get("/collection.html")
    @app.get("/results.html")
    def app_page():
        return send_from_directory(ROOT, request.path.rsplit("/", 1)[-1])

    @app.get("/data/<path:filename>")
    def data_file(filename):
        return send_from_directory(ROOT / "data", filename)

    @app.get("/api/session")
    def session_info():
        token = session.setdefault("csrf_token", secrets.token_urlsafe(32))
        authenticated = bool(current_user.is_authenticated)
        return jsonify(
            csrfToken=token,
            user={"username": current_user.username} if authenticated else None,
            collection=collection_for(current_user.id) if authenticated else None,
        )

    @app.post("/api/register")
    def register():
        blocked = csrf_required()
        if blocked:
            return blocked
        if record_auth_attempt() is None:
            return jsonify(error="Trop de tentatives. Réessaie dans 15 minutes."), 429
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(error="Requête invalide."), 400
        username = payload.get("username", "")
        if not isinstance(username, str):
            return jsonify(error="Nom d’utilisateur invalide."), 400
        username = username.strip()
        password = payload.get("password", "")
        if not USERNAME_RE.fullmatch(username):
            return jsonify(error="Le nom doit contenir 3 à 24 lettres, chiffres, tirets ou underscores."), 400
        if not isinstance(password, str) or not 12 <= len(password) <= 128:
            return jsonify(error="Le mot de passe doit contenir entre 12 et 128 caractères."), 400
        db = get_db()
        try:
            cursor = db.execute(
                "INSERT INTO users(username, password_hash, created_at) VALUES (?, ?, ?)",
                (username, generate_password_hash(password), datetime.now(timezone.utc).isoformat()),
            )
            db.commit()
        except sqlite3.IntegrityError:
            return jsonify(error="Ce nom d’utilisateur est déjà pris."), 409
        clear_auth_attempts(request.remote_addr or "unknown")
        user = User(cursor.lastrowid, username)
        login_user(user, remember=True, fresh=True)
        session["csrf_token"] = secrets.token_urlsafe(32)
        return jsonify(user={"username": username}, collection=DEFAULT_COLLECTION), 201

    @app.post("/api/login")
    def login():
        blocked = csrf_required()
        if blocked:
            return blocked
        address = request.remote_addr or "unknown"
        if record_auth_attempt() is None:
            return jsonify(error="Trop de tentatives. Réessaie dans 15 minutes."), 429
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(error="Requête invalide."), 400
        username = payload.get("username", "")
        if not isinstance(username, str):
            return jsonify(error="Nom d’utilisateur invalide."), 400
        username = username.strip()
        password = payload.get("password", "")
        row = get_db().execute("SELECT id, username, password_hash FROM users WHERE username = ? COLLATE NOCASE", (username,)).fetchone()
        if not row or not isinstance(password, str) or not check_password_hash(row["password_hash"], password):
            return jsonify(error="Nom d’utilisateur ou mot de passe incorrect."), 401
        clear_auth_attempts(address)
        login_user(User(row["id"], row["username"]), remember=True, fresh=True)
        session["csrf_token"] = secrets.token_urlsafe(32)
        return jsonify(user={"username": row["username"]}, collection=collection_for(row["id"]))

    @app.post("/api/logout")
    @login_required
    def logout():
        blocked = csrf_required()
        if blocked:
            return blocked
        logout_user()
        session.clear()
        return jsonify(ok=True)

    @app.get("/api/collection")
    @login_required
    def get_collection():
        return jsonify(collection=collection_for(current_user.id))

    @app.put("/api/collection")
    @login_required
    def put_collection():
        blocked = csrf_required()
        if blocked:
            return blocked
        payload = request.get_json(silent=True)
        if not validate_collection(payload):
            return jsonify(error="Format de collection invalide."), 400
        write_collection(current_user.id, payload)
        return jsonify(ok=True)

    return app


app = create_app()


if __name__ == "__main__":
    from waitress import serve

    serve(app, host=os.environ.get("HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8000")))