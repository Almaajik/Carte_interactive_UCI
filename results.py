"""Récupère le vainqueur et le classement des courses terminées.

Source : Wikipédia anglophone (API officielle MediaWiki, texte sous licence CC BY-SA 4.0).
Limite connue : Wikipédia ne publie souvent que le haut du classement (top 10, parfois plus)
et n'a pas de page pour les petites courses. Les courses sans classement trouvé
n'affichent simplement rien sur le site.

Usage :
    py results.py                      # traite jusqu'à 40 courses terminées sans résultat
    py results.py --limit 300          # rattrapage d'un gros retard (compter ~2 s par course)
    py results.py --race "Il Lombardia" --year 2026   # TEST : affiche ce qui est trouvé, n'écrit rien

Fichiers :
    data/results/index.json     {clé de course: {slug, winner, team}}  (lu par le site)
    data/results/<slug>.json    classement complet d'une course          (lu par results.html)
    data/results/misses.json    courses sans résultat (nouvel essai chaque jour pendant 14 jours)
"""
import argparse
import difflib
import json
import os
import re
import sys
import time
import unicodedata
from datetime import date, timedelta
from pathlib import Path
from urllib.parse import quote

import requests
from bs4 import BeautifulSoup

TODAY = os.environ.get("TODAY") or date.today().isoformat()
RACES = Path("data/races.json")
DIR = Path("data/results")
INDEX = DIR / "index.json"
MISSES = DIR / "misses.json"
API = "https://en.wikipedia.org/w/api.php"
CONTACT_EMAIL = os.environ.get("CONTACT_EMAIL")
HEADERS = {"User-Agent": f"CarteInteractiveUCI/0.1 ({CONTACT_EMAIL})" if CONTACT_EMAIL else "CarteInteractiveUCI/0.1"}
RETRY_DAYS = 14
MAX_ROWS = 200
WOMEN_RE = re.compile(r"\b(?:women|woman|female|femmes?|dames|feminas?|femininas?|femeninas?|femminil[ei]|féminines?)\b", re.I)
MEN_RE = re.compile(r"\b(?:men|male|hommes?)\b", re.I)


# ---------------------------------------------------------------- utilitaires
def load(path, default):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")


def norm(s: str) -> str:
    s = unicodedata.normalize("NFD", s.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def slugify(r: dict) -> str:
    return "-".join(norm(f"{r['name']} {r['start']} {r['country']}").split())


def race_key(r: dict) -> str:
    # doit rester identique à rr.key dans index.html
    return f"{r['name']}|{r['start']}|{r['country']}"


# ---------------------------------------------------------------- Wikipédia
def is_womens_race(r: dict) -> bool:
    classes = " ".join(r.get("classes", []))
    return bool(re.search(r"\b[12]\.WWT\b", classes, re.I) or WOMEN_RE.search(r["name"]))


def wiki_title(name: str, year: str, women_race: bool = False):
    """Trouve la page de l'édition (ex. « 2026 Il Lombardia »)."""
    query = f"{year} {name}" + (" women's race" if women_race else "")
    r = requests.get(API, headers=HEADERS, timeout=30, params={
        "action": "query", "list": "search", "srsearch": query,
        "srlimit": 10, "format": "json", "formatversion": 2})
    r.raise_for_status()
    best, best_score = None, 0.0
    for hit in r.json().get("query", {}).get("search", []):
        t = hit["title"]
        if not t.startswith(year) or re.search(r"\bstage\b|\bnational\b", t, re.I):
            continue
        title_text = t[len(year):]
        title_is_women = bool(WOMEN_RE.search(title_text))
        if not women_race and title_is_women:
            continue
        score = difflib.SequenceMatcher(None, norm(name), norm(WOMEN_RE.sub("", title_text))).ratio()
        if women_race:
            score += 0.25 if title_is_women else -0.15
        if score > best_score:
            best, best_score = t, score
    return best if best_score >= 0.6 else None


def wiki_html(title: str) -> str:
    r = requests.get(API, headers=HEADERS, timeout=30, params={
        "action": "parse", "page": title, "prop": "text", "redirects": 1,
        "format": "json", "formatversion": 2})
    r.raise_for_status()
    return r.json()["parse"]["text"]


RANK_H = ("rank", "pos", "pos.", "place", "position", "#")
RIDER_H = ("rider", "cyclist", "name")


def cell_text(td) -> str:
    for junk in td.find_all(["sup", "style"]):
        junk.decompose()
    t = td.get_text(" ", strip=True)
    return re.sub(r"\s+", " ", t).strip()


def columns(table):
    """Repère les colonnes rang / coureur / équipe / temps d'après l'en-tête."""
    first = table.find("tr")
    if first is None:
        return None
    heads = [norm(c.get_text(" ", strip=True)) for c in first.find_all(["th", "td"])]
    idx = {}
    for i, h in enumerate(heads):
        if "rank" not in idx and (h in RANK_H or h.startswith("rank")):
            idx["rank"] = i
        elif "rider" not in idx and any(k in h for k in RIDER_H):
            idx["rider"] = i
        elif "team" not in idx and "team" in h:
            idx["team"] = i
        elif "time" not in idx and ("time" in h or "gap" in h):
            idx["time"] = i
    return idx if "rank" in idx and "rider" in idx else None


def parse_results(html: str, stage_race: bool, women_race: bool = False, title: str = ""):
    """Renvoie {'classification', 'rows'} ou None si aucun tableau de classement n'est trouvé."""
    soup = BeautifulSoup(html, "html.parser")
    candidates = []
    for table in soup.select("table.wikitable"):
        idx = columns(table)
        if not idx:
            continue
        heading = table.find_previous(["h2", "h3", "h4"])
        caption = table.find("caption")
        label = " ".join((
            heading.get_text(" ", strip=True) if heading else "",
            caption.get_text(" ", strip=True) if caption else "",
        ))
        gender = "women" if WOMEN_RE.search(label) else "men" if MEN_RE.search(label) else None
        candidates.append((table, idx, label, gender))
    if not candidates:
        return None

    title_is_women = bool(WOMEN_RE.search(title))
    if women_race:
        matching = [c for c in candidates if c[3] == "women"]
        if matching:
            candidates = matching
        elif any(c[3] == "men" for c in candidates) or not title_is_women:
            return None
    else:
        candidates = [c for c in candidates if c[3] != "women"]
        if not candidates:
            return None

    pick = candidates[0]
    if stage_race:
        for c in candidates:
            if re.search(r"general|overall|final", c[2], re.I):
                pick = c
                break
    table, idx, heading, _ = pick

    rows = []
    for tr in table.find_all("tr")[1:]:
        cells = tr.find_all(["th", "td"])
        if len(cells) <= max(idx.values()):
            continue
        rank = cell_text(cells[idx["rank"]])
        if not rank.isdigit():
            continue
        row = {"rank": int(rank), "rider": cell_text(cells[idx["rider"]])}
        if "team" in idx:
            row["team"] = cell_text(cells[idx["team"]])
        if "time" in idx:
            row["time"] = cell_text(cells[idx["time"]])
        if row["rider"]:
            rows.append(row)
        if len(rows) >= MAX_ROWS:
            break
    if len(rows) < 3:
        return None
    return {"classification": heading or ("Classement général" if stage_race else "Résultat"), "rows": rows}


def fetch_result(r: dict):
    year = r["start"][:4]
    women_race = is_womens_race(r)
    title = wiki_title(r["name"], year, women_race=women_race)
    if not title:
        return None, "page Wikipédia introuvable"
    time.sleep(0.5)
    parsed = parse_results(wiki_html(title), stage_race=r["start"] != r["end"],
                           women_race=women_race, title=title)
    if not parsed:
        return None, f"pas de tableau de classement sur « {title} »"
    return {
        "key": race_key(r), "name": r["name"], "country": r["country"], "start": r["start"], "end": r["end"],
        "classes": r.get("classes", []), "title": title,
        "url": "https://en.wikipedia.org/wiki/" + quote(title.replace(" ", "_")),
        "source": "Wikipédia (CC BY-SA 4.0)", "fetched": TODAY, **parsed,
    }, None


# ---------------------------------------------------------------- programme principal
def run_test(name: str, year: str, women_race: bool = False):
    title = wiki_title(name, year, women_race=women_race)
    print("Page trouvée :", title)
    if not title:
        return
    parsed = parse_results(wiki_html(title), stage_race=False, women_race=women_race, title=title)
    if not parsed:
        print("Aucun tableau de classement reconnu.")
        return
    print("Section :", parsed["classification"], "|", len(parsed["rows"]), "lignes")
    for row in parsed["rows"][:10]:
        print(" ", row)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=40)
    ap.add_argument("--force", action="store_true", help="réessaie aussi les courses abandonnées")
    ap.add_argument("--race")
    ap.add_argument("--year")
    ap.add_argument("--women", action="store_true", help="teste un résultat féminin")
    args = ap.parse_args()
    if args.race:
        return run_test(args.race, args.year or TODAY[:4], women_race=args.women)

    races = load(RACES, [])
    index, misses = load(INDEX, {}), load(MISSES, {})

    def due(r):
        if not r.get("start") or not r.get("end") or r["end"] >= TODAY:
            return False
        k = race_key(r)
        if k in index:
            return False
        m = misses.get(k)
        if m and not args.force:
            if m["last"] == TODAY:
                return False
            if TODAY > (date.fromisoformat(r["end"]) + timedelta(days=RETRY_DAYS)).isoformat():
                return False
        return True

    todo = sorted((r for r in races if due(r)), key=lambda r: r["end"], reverse=True)[: args.limit]
    ok = 0
    for r in todo:
        k = race_key(r)
        try:
            res, why = fetch_result(r)
        except Exception as e:  # réseau, API : on réessaiera demain
            res, why = None, f"erreur : {e}"
        if res:
            slug = slugify(r)
            save(DIR / f"{slug}.json", res)
            top = res["rows"][0]
            index[k] = {"slug": slug, "winner": top["rider"], **({"team": top["team"]} if top.get("team") else {})}
            misses.pop(k, None)
            ok += 1
            print(f"OK   {r['name']} ({r['start']}) -> {top['rider']} [{len(res['rows'])} lignes]")
        else:
            misses[k] = {"last": TODAY, "tries": misses.get(k, {}).get("tries", 0) + 1, "reason": why}
            print(f"--   {r['name']} ({r['start']}) : {why}")
        time.sleep(1)

    save(INDEX, index)
    save(MISSES, misses)
    print(f"\n{ok} classements ajoutés sur {len(todo)} essais. Total : {len(index)}.")


if __name__ == "__main__":
    main()