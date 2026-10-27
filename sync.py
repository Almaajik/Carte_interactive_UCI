"""Mise à jour quotidienne : récupère le calendrier, détecte ce qui a changé,
géocode seulement les nouvelles courses et met à jour data/races.json.

Usage :  py sync.py

Ce que fait le script :
- nouvelle course dans le flux            -> "added"      (géocodée, marquée "first_seen")
- course future dont la date a bougé      -> "moved"
- classe UCI ou date de fin modifiée      -> "changed"
- course future qui disparaît du flux     -> "cancelled"  (retirée de la carte)
- course passée absente du flux           -> conservée (archive)
- data/changes.json : historique des changements
- data/last_changes.md : résumé de CE passage (absent s'il n'y a rien de neuf)

Sécurité : si le flux semble cassé (très peu d'événements, ou une grosse part des
courses futures qui disparaît d'un coup), le script s'arrête sans rien modifier.
"""
import json
import os
import sys
from datetime import date
from pathlib import Path

import fetch_calendar as fc
import geocode as g

TODAY = os.environ.get("TODAY") or date.today().isoformat()
CHANGES = Path("data/changes.json")
LAST = Path("data/last_changes.md")


def load(path, default):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def year(r):
    return (r["start"] or "")[:4]


def k3(r):
    return (r["name"].lower(), r["country"], r["start"])


def label(r):
    d = r["start"] if r["start"] == r["end"] else f"{r['start']} → {r['end']}"
    return f"{r['name']} ({r['country']}), {d}, {', '.join(r['classes']) or 'classe ?'}"


def main():
    raw = fc.fetch()
    if len(raw) < 50:
        sys.exit(f"Flux suspect : seulement {len(raw)} événements. Rien n'a été modifié.")

    cur_list = g.merge(raw)
    prev_list = load(g.OUT, None)
    cache = load(g.CACHE, {})
    overrides = load(g.OVERRIDES, {})

    def needs_geocoding(old, r):
        if old is None or old.get("coords") is None:
            return True
        return old["coords"]["precision"] == "country" or f"{r['name']}|{r['country']}" in overrides

    g.RAW.parent.mkdir(exist_ok=True)
    g.RAW.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")

    # ---------- première exécution : on géocode tout, sans rien signaler ----------
    if prev_list is None:
        for r in cur_list:
            r["coords"] = g.locate(r, cache, overrides)
        g.OUT.write_text(json.dumps(cur_list, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Première exécution : {len(cur_list)} courses enregistrées.")
        return

    prev = {k3(r): r for r in prev_list}
    cur = {k3(r): r for r in cur_list}

    added = [cur[k] for k in cur if k not in prev]
    gone = [prev[k] for k in prev if k not in cur]
    gone_future = [r for r in gone if (r["start"] or "") >= TODAY]
    gone_past = [r for r in gone if (r["start"] or "") < TODAY]

    # garde-fou contre un flux cassé
    prev_future = sum(1 for r in prev_list if (r["start"] or "") >= TODAY)
    if len(gone_future) > max(10, 0.3 * prev_future):
        sys.exit(f"{len(gone_future)} courses futures disparaissent d'un coup : flux suspect. "
                 "Rien n'a été modifié.")

    # une course dont la date a changé = disparue + apparue avec le même nom
    moved = []
    for a in list(added):
        for o in list(gone_future):
            if o["name"].lower() == a["name"].lower() and o["country"] == a["country"] and year(o) == year(a):
                moved.append((o, a))
                added.remove(a)
                gone_future.remove(o)
                break
    moved_old_by_new = {k3(a): o for o, a in moved}

    changed = []
    for k in cur:
        if k in prev and (sorted(prev[k]["classes"]) != sorted(cur[k]["classes"]) or prev[k]["end"] != cur[k]["end"]):
            changed.append((prev[k], cur[k]))

    # ---------- reconstruction de la liste ----------
    final = []
    to_fix = []
    for k, r in cur.items():
        old = prev.get(k) or moved_old_by_new.get(k)
        r["first_seen"] = (old or {}).get("first_seen") if old else TODAY
        if old and not needs_geocoding(old, r):
            r["coords"] = old["coords"]
        else:
            r["coords"] = g.locate(r, cache, overrides)
        if old is None and (r["coords"] is None or r["coords"]["precision"] == "country"):
            to_fix.append(r)
        if r["first_seen"] is None:
            del r["first_seen"]
        final.append(r)
    final += gone_past  # archive des courses passées
    final.sort(key=lambda r: (r["start"] or "", r["name"]))
    g.OUT.write_text(json.dumps(final, ensure_ascii=False, indent=2), encoding="utf-8")

    # ---------- journal des changements ----------
    log = []
    for r in added:
        log.append({"date": TODAY, "type": "added", "race": label(r)})
    for o, a in moved:
        log.append({"date": TODAY, "type": "moved", "race": label(a), "before": label(o)})
    for o, a in changed:
        log.append({"date": TODAY, "type": "changed", "race": label(a), "before": label(o)})
    for r in gone_future:
        log.append({"date": TODAY, "type": "cancelled", "race": label(r)})

    if not log:
        LAST.unlink(missing_ok=True)
        print(f"Aucun changement. {len(final)} courses au total.")
        return

    history = load(CHANGES, [])
    CHANGES.write_text(json.dumps((history + log)[-500:], ensure_ascii=False, indent=2), encoding="utf-8")

    titles = {"added": "Nouvelles courses", "moved": "Dates modifiées",
              "changed": "Classe ou durée modifiée", "cancelled": "Courses retirées du calendrier"}
    md = [f"Mise à jour du {TODAY} : {len(log)} changement(s).", ""]
    for t, title in titles.items():
        items = [e for e in log if e["type"] == t]
        if items:
            md.append(f"## {title} ({len(items)})")
            for e in items:
                md.append(f"- {e['race']}" + (f"  (avant : {e['before']})" if "before" in e else ""))
            md.append("")
    if to_fix:
        md.append("## À placer précisément")
        md.append("Ces nouvelles courses n'ont que le centre du pays. Ajoute-les dans data/overrides.json :")
        for r in to_fix:
            md.append(f"- `{r['name']}|{r['country']}`")
        md.append("")
    LAST.write_text("\n".join(md), encoding="utf-8")
    print("\n".join(md))


if __name__ == "__main__":
    main()