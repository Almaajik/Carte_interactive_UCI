"""Étape 2 : fusionne les doublons, corrige les dates et géocode les courses.

Usage :  py geocode.py
Entrée : data/races_raw.json
Sortie : data/races.json   (cache : data/geocache.json)
Corrections manuelles : data/overrides.json  (voir plus bas)

Constats sur les données d'Inrng :
- le champ "location" ne contient que le PAYS (ex. "Belgium") ;
- DTEND est exclusif (une course d'un jour a end = start + 1 jour) ;
- une même course apparaît souvent deux fois (hommes + femmes).

Précision du point : "place" (course trouvée), "country" (centre du pays, à
corriger), "override" (corrigé à la main).

overrides.json : {"Brabantse Pijl|Belgium": {"lat": 50.88, "lon": 4.70}, ...}
"""
import json
import os
import re
import time
import unicodedata
from datetime import date, timedelta
from pathlib import Path

import requests

RAW = Path("data/races_raw.json")
OUT = Path("data/races.json")
CACHE = Path("data/geocache.json")
OVERRIDES = Path("data/overrides.json")
CONTACT_EMAIL = os.environ.get("CONTACT_EMAIL")
HEADERS = {"User-Agent": f"CarteInteractiveUCI/0.1 ({CONTACT_EMAIL})" if CONTACT_EMAIL else "CarteInteractiveUCI/0.1"}
NEGATIVE_CACHE_TTL_DAYS = 30
NEGATIVE_CACHE_KEY = "_not_found"

CLASS_RE = re.compile(r"\b[12]\.(?:UWT|WWT|Pro|HC|Ncup|1|2)\b")


def clean_name(name: str) -> str:
    """Retire la classe UCI et les parenthèses : 'Brabantse Pijl (1.Pro)' -> 'Brabantse Pijl'."""
    name = re.sub(r"\(.*?\)", "", name)
    name = CLASS_RE.sub("", name)
    return re.sub(r"\s+", " ", name).strip(" -–:")


def inclusive_end(start: str, end: str) -> str:
    """DTEND iCal est exclusif pour les événements « toute la journée »."""
    if not start or not end:
        return end or start
    e = date.fromisoformat(end) - timedelta(days=1)
    return max(e, date.fromisoformat(start)).isoformat()


def merge(raw: list) -> list:
    """Une entrée par (nom, début, pays) ; les classes hommes/femmes sont regroupées."""
    groups = {}
    for r in raw:
        name = clean_name(r["name"])
        country = r["location"] or ""
        key = (name.lower(), r["start"], country)
        g = groups.setdefault(
            key,
            {
                "name": name,
                "country": country,
                "start": r["start"],
                "end": inclusive_end(r["start"], r["end"]),
                "classes": [],
                "entries": 0,
            },
        )
        g["entries"] += 1
        if r["uci_class"] and r["uci_class"] not in g["classes"]:
            g["classes"].append(r["uci_class"])
    return sorted(groups.values(), key=lambda g: (g["start"] or "", g["name"]))


def nominatim(q: str):
    r = requests.get(
        "https://nominatim.openstreetmap.org/search",
        params={"q": q, "format": "json", "limit": 1, "accept-language": "en", "addressdetails": 1},
        headers=HEADERS,
        timeout=30,
    )
    r.raise_for_status()
    data = r.json()
    if not data:
        return None
    address = data[0].get("address") or {}
    return {"lat": float(data[0]["lat"]), "lon": float(data[0]["lon"]),
            "display": data[0].get("display_name", ""),
            "country": address.get("country")}


def canonical_country(country: str) -> str:
    country = unicodedata.normalize("NFD", country.casefold())
    country = "".join(c for c in country if unicodedata.category(c) != "Mn")
    normalized = re.sub(r"[^a-z0-9]+", " ", country).strip()
    aliases = {
        "czechia": "czech republic",
        "cote d ivoire": "ivory coast",
        "ivory coast": "ivory coast",
        "russian federation": "russia",
        "russia": "russia",
        "turkiye": "turkey",
        "turkey": "turkey",
        "united states": "united states of america",
        "united states of america": "united states of america",
    }
    return aliases.get(normalized, normalized)


def country_matches(expected: str, hit: dict) -> bool:
    actual = hit.get("country")
    if actual:
        return canonical_country(expected) == canonical_country(actual)
    # Older cache entries only contain display_name; compare full address components.
    return any(canonical_country(part.strip()) == canonical_country(expected)
               for part in hit.get("display", "").split(","))


def save_cache(cache: dict):
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")


def lookup(q: str, cache: dict):
    cached = cache.get(q)
    if q in cache and cached is None:
        cached = {NEGATIVE_CACHE_KEY: date.today().isoformat()}
        cache[q] = cached
        save_cache(cache)
    if isinstance(cached, dict) and NEGATIVE_CACHE_KEY in cached:
        try:
            age = date.today() - date.fromisoformat(cached[NEGATIVE_CACHE_KEY])
        except (TypeError, ValueError):
            age = timedelta(days=NEGATIVE_CACHE_TTL_DAYS)
        if age < timedelta(days=NEGATIVE_CACHE_TTL_DAYS):
            return None
    elif q in cache:
        return cached

    result = nominatim(q)
    cache[q] = result if result is not None else {NEGATIVE_CACHE_KEY: date.today().isoformat()}
    save_cache(cache)
    time.sleep(1.1)  # limite Nominatim : 1 requête/seconde
    return result


def locate(race: dict, cache: dict, overrides: dict):
    key = f"{race['name']}|{race['country']}"
    if key in overrides:
        return {"lat": overrides[key]["lat"], "lon": overrides[key]["lon"], "precision": "override"}

    hit = lookup(f"{race['name']}, {race['country']}", cache)
    # on n'accepte le résultat que s'il est bien dans le bon pays
    if hit and race["country"] and country_matches(race["country"], hit):
        return {"lat": hit["lat"], "lon": hit["lon"], "precision": "place"}

    hit = lookup(race["country"], cache) if race["country"] else None
    if hit:
        return {"lat": hit["lat"], "lon": hit["lon"], "precision": "country"}
    return None


def main():
    raw = json.loads(RAW.read_text(encoding="utf-8"))
    races = merge(raw)
    print(f"{len(raw)} entrées brutes -> {len(races)} courses distinctes")

    cache = json.loads(CACHE.read_text(encoding="utf-8")) if CACHE.exists() else {}
    overrides = json.loads(OVERRIDES.read_text(encoding="utf-8")) if OVERRIDES.exists() else {}

    for i, race in enumerate(races, 1):
        race["coords"] = locate(race, cache, overrides)
        if i % 25 == 0:
            print(f"  {i}/{len(races)}")

    OUT.write_text(json.dumps(races, ensure_ascii=False, indent=2), encoding="utf-8")

    by = {"place": 0, "country": 0, "override": 0, None: 0}
    for r in races:
        by[r["coords"]["precision"] if r["coords"] else None] += 1
    print(f"Précis (lieu trouvé)      : {by['place']}")
    print(f"Corrigés à la main        : {by['override']}")
    print(f"Centre du pays seulement  : {by['country']}")
    print(f"Introuvables              : {by[None]}")
    todo = [r for r in races if not r["coords"] or r["coords"]["precision"] == "country"]
    if todo:
        print("\nÀ corriger dans data/overrides.json :")
        for r in todo:
            print(f"  {r['name']}|{r['country']}")


if __name__ == "__main__":
    main()