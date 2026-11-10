"""Generate estimated route profiles for races in the local calendar."""

import json
import re
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parent
RACES_PATH = ROOT / "data" / "races.json"
OUTPUT_PATH = ROOT / "data" / "race_profiles.json"

PROFILE_OVERRIDES = (
    (r"tour de france femmes", 28),
    (r"tour de france", 32),
    (r"giro d italia", 34),
    (r"vuelta a espana", 36),
    (r"tour of the alps|tour de l ain", 40),
    (r"tour de suisse|tour de romandie", 30),
    (r"paris nice|tirreno adriatico|volta a catalunya", 27),
    (r"itzulia|basque country", 36),
    (r"il lombardia|giro dell emilia|giro dell emilia donne", 38),
    (r"liege bastogne liege", 36),
    (r"fleche wallonne", 35),
    (r"faun ardeche classic|faun drome classic|gp industria|gp miguel indurain|"
     r"clasica san sebastian|trofeo laigueglia|utsunomiya japan cup", 24),
    (r"gp de montreal|grand prix cycliste de montreal", 28),
    (r"gp de quebec|grand prix cycliste de quebec", 18),
    (r"amstel gold race", 24),
    (r"strade bianche", 18),
    (r"tour down under", 14),
    (r"tour of oman|tour of austria|tour of slovenia|tour of britain", 23),
    (r"tour of taiwan|tour of hainan|tour de taihu lake|tour of chongming island", 3),
    (r"tour de langkawi|tour of guangxi|uae tour", 14),
    (r"tour of flanders|ronde van vlaanderen", 10),
    (r"gent wevelgem|kuurne brussels kuurne|dwars door vlaanderen", 8),
    (r"paris roubaix|scheldeprijs|sparkassen munsterland giro|classica de almeria", 2),
    (r"milan san remo|milano san remo|milano sanremo", 4),
    (r"tour of chongming|copenhagen sprint|tour of taihu lake", 2),
)

SPRINT_FINISHES = re.compile(
    r"adac cyclassics|classica de almeria|brussels cycling classic|"
    r"copenhagen sprint|scheldeprijs|sparkassen munsterland giro|"
    r"tour of chongming island|tour of hainan|tour de taiwan|"
    r"paris chauny|kampioenscap van vlaanderen|gooikse pijl|"
    r"tour of guangxi|tour of taihu lake|tour de langkawi",
)

TIME_TRIAL = re.compile(r"\b(tt|time trial|chrono|contre la montre|mixed relay)\b")
MOUNTAIN_RACE = re.compile(
    r"tour of the alps|tour de l ain|tour de france|giro d italia|"
    r"vuelta a espana|tour de suisse|tour de romandie|paris nice|"
    r"tirreno adriatico|volta a catalunya|itzulia|basque country|"
    r"il lombardia|giro dell emilia|liege bastogne liege|fleche wallonne|"
    r"tour of austria|tour of slovenia|tour of oman",
)


def normalize(value):
    value = unicodedata.normalize("NFD", str(value or ""))
    value = "".join(char for char in value if unicodedata.category(char) != "Mn")
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def race_slug(race):
    identity = f"{race['name']} {race.get('start') or ''} {race.get('country') or ''}"
    return normalize(identity).replace(" ", "-")


def infer_profile(race):
    name = normalize(race.get("name"))
    classes = " ".join(race.get("classes") or [])
    is_time_trial = bool(TIME_TRIAL.search(name))

    uci_classes = set(classes.split())
    climb_pct = 0 if is_time_trial else 16 if uci_classes & {"1.UWT", "2.UWT", "1.WWT", "2.WWT"} else 12
    for pattern, percentage in PROFILE_OVERRIDES:
        if re.search(pattern, name):
            climb_pct = percentage
            break
    else:
        if not is_time_trial and MOUNTAIN_RACE.search(name):
            climb_pct = 30
        elif not is_time_trial and race.get("start") != race.get("end"):
            climb_pct = 20
        elif not is_time_trial and re.search(r"paris roubaix|scheldeprijs|sprint|classic", name):
            climb_pct = 5

    sprint_finish = not is_time_trial and (
        bool(SPRINT_FINISHES.search(name)) or climb_pct <= 4
    )
    sprint_pct = 20 if sprint_finish else 0
    climb_pct = min(climb_pct, 80 if sprint_finish else 100)
    rolling_pct = 100 - climb_pct - sprint_pct
    escape_probability = 50 if climb_pct >= 28 else 30 if climb_pct >= 12 else 10

    if is_time_trial:
        terrains = ["rouleur", "rouleur", "rouleur", "rouleur"]
    elif climb_pct >= 28:
        terrains = ["rouleur", "mountain", "mountain", "mountain"]
    elif sprint_finish:
        terrains = ["rouleur", "mountain" if climb_pct >= 10 else "rouleur", "rouleur", "sprint"]
    else:
        terrains = ["rouleur", "mountain", "rouleur", "mountain" if climb_pct >= 18 else "rouleur"]

    labels = {
        "mountain": "Secteur de montée",
        "rouleur": "Secteur roulant",
        "sprint": "Arrivée favorable au sprint",
    }
    key_points = [
        {"progress": progress, "terrain": terrain, "label": labels[terrain]}
        for progress, terrain in zip((20, 45, 70, 100), terrains)
    ]
    return {
        "climb_pct": climb_pct,
        "rolling_pct": rolling_pct,
        "sprint_pct": sprint_pct,
        "sprint_finish": sprint_finish,
        "escape_probability": escape_probability,
        "profile_source": "Estimation automatique par nom, catégorie UCI et format de course",
        "estimated": True,
        "key_points": key_points,
    }


def generate_profiles(races):
    return {
        race_slug(race): {
            "name": race["name"],
            "race_date": race.get("start"),
            "country": race.get("country") or "",
            **infer_profile(race),
        }
        for race in races
        if race.get("name") and race.get("start")
    }


def main():
    races = json.loads(RACES_PATH.read_text(encoding="utf-8"))
    profiles = generate_profiles(races)
    OUTPUT_PATH.write_text(
        json.dumps(profiles, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"{len(profiles)} estimated route profiles written to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
