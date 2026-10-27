"""Récupère le calendrier route (iCal d'Inrng) et l'écrit en JSON.

Usage direct :  py fetch_calendar.py   ->  data/races_raw.json
Utilisé aussi par sync.py (fonction fetch()).
"""
import json
import re
from pathlib import Path

import requests
from icalendar import Calendar

ICS_URL = (
    "https://calendar.google.com/calendar/ical/"
    "5c9dc1a627cf55f1653d17573c2df58075d949559ec87e484b0cf90fa78bbf6d"
    "%40group.calendar.google.com/public/basic.ics"
)
OUT = Path("data/races_raw.json")

# Classes UCI : 1.UWT, 2.UWT, 1.WWT, 2.WWT, 1.Pro, 2.Pro, 1.1, 2.1, 1.2, 2.2, HC...
CLASS_RE = re.compile(r"\b([12])\.(UWT|WWT|Pro|HC|Ncup|1|2)\b")


def to_iso(value):
    """DTSTART/DTEND peuvent être une date ou un datetime."""
    return value.isoformat() if value is not None else None


def fetch():
    """Télécharge le flux iCal et renvoie la liste des événements (dicts)."""
    resp = requests.get(ICS_URL, timeout=30)
    resp.raise_for_status()
    cal = Calendar.from_ical(resp.content)

    races = []
    for ev in cal.walk("VEVENT"):
        summary = str(ev.get("SUMMARY", "")).strip()
        description = str(ev.get("DESCRIPTION", "")).strip()
        m = CLASS_RE.search(summary) or CLASS_RE.search(description)
        races.append(
            {
                "uid": str(ev.get("UID", "")),
                "name": summary,
                "uci_class": m.group(0) if m else None,
                "start": to_iso(ev.decoded("DTSTART")) if ev.get("DTSTART") else None,
                "end": to_iso(ev.decoded("DTEND")) if ev.get("DTEND") else None,
                "location": str(ev.get("LOCATION", "")).strip() or None,
                "description": description or None,
            }
        )
    races.sort(key=lambda r: r["start"] or "")
    return races


def main():
    races = fetch()
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(races, ensure_ascii=False, indent=2), encoding="utf-8")
    with_class = sum(1 for r in races if r["uci_class"])
    with_loc = sum(1 for r in races if r["location"])
    print(f"{len(races)} courses écrites dans {OUT}")
    print(f"  avec classe UCI détectée : {with_class}")
    print(f"  avec un champ lieu       : {with_loc}")


if __name__ == "__main__":
    main()