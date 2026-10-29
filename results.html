<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Classement</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Hanken+Grotesk:wght@400;500;600;700&family=Unbounded:wght@500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --ink: #e9eef8; --panel: rgba(255,255,255,.82); --line: rgba(40,70,140,.16); --line-strong: rgba(40,70,140,.34);
    --text: #101634; --muted: #566190; --wt: #e4156f; --pro: #0a93c9; --other: #7b84c9;
    --display: "Unbounded", "Trebuchet MS", system-ui, sans-serif;
    --body: "Hanken Grotesk", system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  * { box-sizing: border-box; }
  html { background: var(--ink); }
  body { margin: 0; min-height: 100%; color: var(--text); font: 15px/1.5 var(--body);
         background: radial-gradient(900px 500px at 85% -10%, rgba(10,147,201,.18), transparent 60%),
                     radial-gradient(800px 500px at -10% 10%, rgba(228,21,111,.12), transparent 60%), var(--ink); }
  :focus-visible { outline: 2px solid var(--pro); outline-offset: 2px; }
  main { max-width: 860px; margin: 0 auto; padding: 22px 16px 60px; }
  .back { display: inline-flex; align-items: center; gap: 8px; color: var(--text); text-decoration: none; font-weight: 600;
          padding: 8px 14px; border-radius: 999px; border: 1px solid var(--line); background: var(--panel); }
  .back:hover { border-color: var(--line-strong); }
  .card { margin-top: 18px; background: var(--panel); border: 1px solid var(--line); border-radius: 18px;
          box-shadow: 0 10px 40px rgba(30,50,110,.14); -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px); overflow: hidden; }
  header { padding: 22px 22px 16px; border-left: 4px solid var(--c, var(--pro)); }
  h1 { margin: 0 0 6px; font: 600 clamp(20px, 4vw, 28px)/1.2 var(--display); letter-spacing: -.01em; overflow-wrap: anywhere; }
  .meta { color: var(--muted); }
  .winner { margin-top: 12px; font-weight: 600; }
  .winner small { font-weight: 500; color: var(--muted); }
  .scroll { overflow-x: auto; border-top: 1px solid var(--line); }
  table { width: 100%; border-collapse: collapse; min-width: 520px; }
  th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--line); white-space: nowrap; }
  td.rider { white-space: normal; font-weight: 600; }
  th { position: sticky; top: 0; background: #f3f6fd; font-size: 13px; color: var(--muted); font-weight: 600; }
  td.rank, th.rank { width: 56px; text-align: right; font-variant-numeric: tabular-nums; }
  td.time { font-variant-numeric: tabular-nums; color: var(--muted); }
  tbody tr:hover { background: rgba(255,255,255,.7); }
  tr.p1 td.rank, tr.p2 td.rank, tr.p3 td.rank { font-weight: 700; color: var(--c, var(--pro)); }
  footer { padding: 14px 22px 18px; color: var(--muted); font-size: 13px; border-top: 1px solid var(--line); }
  footer a { color: var(--text); }
  .msg { padding: 28px 22px; color: var(--muted); }
  .note { padding: 10px 22px; font-size: 13px; color: var(--muted); border-top: 1px solid var(--line); }
</style>
</head>
<body>
<main>
  <a class="back" href="index.html">← Retour à la carte</a>
  <article class="card" id="card">
    <p class="msg" id="msg">Chargement…</p>
  </article>
</main>

<script>
const MONTHS = ["janvier","février","mars","avril","mai","juin","juillet","août","septembre","octobre","novembre","décembre"];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmt = s => { const [y, m, d] = s.split("-").map(Number); return `${d} ${MONTHS[m - 1]} ${y}`; };
const colorFor = classes => {
  const c = (classes || []).join(" ");
  return /UWT|WWT/.test(c) ? "#e4156f" : /Pro|HC/.test(c) ? "#0a93c9" : "#7b84c9";
};

async function main() {
  const slug = new URLSearchParams(location.search).get("race") || "";
  const card = document.getElementById("card");
  if (!/^[a-z0-9-]+$/.test(slug)) { card.innerHTML = '<p class="msg">Aucune course indiquée. Retourne sur la carte et clique sur « Détail ».</p>'; return; }
  const res = await fetch(`data/results/${slug}.json`);
  if (!res.ok) { card.innerHTML = '<p class="msg">Le classement de cette course n’est pas disponible.</p>'; return; }
  const r = await res.json();

  document.title = `${r.name}, classement`;
  card.style.setProperty("--c", colorFor(r.classes));
  const dates = r.start === r.end ? fmt(r.start) : `${fmt(r.start)} au ${fmt(r.end)}`;
  const win = r.rows[0];
  const hasTeam = r.rows.some(x => x.team), hasTime = r.rows.some(x => x.time);
  const partial = r.rows.length < 30;

  card.innerHTML =
    `<header><h1>${esc(r.name)}</h1>` +
    `<div class="meta">${esc(r.country)}, ${esc(dates)}${r.classes.length ? ", " + esc(r.classes.join(" / ")) : ""}</div>` +
    (partial ? `<div class="meta"><strong>Top ${r.rows.length}</strong></div>` : "") +
    `<div class="winner">Vainqueur : ${esc(win.rider)}${win.team ? ` <small>(${esc(win.team)})</small>` : ""}</div></header>` +
    `<div class="scroll"><table><thead><tr><th class="rank">Rang</th><th>Coureur</th>` +
    `${hasTeam ? "<th>Équipe</th>" : ""}${hasTime ? "<th>Temps</th>" : ""}</tr></thead><tbody>` +
    r.rows.map(x => `<tr class="${x.rank <= 3 ? "p" + x.rank : ""}"><td class="rank">${x.rank}</td><td class="rider">${esc(x.rider)}</td>` +
      `${hasTeam ? `<td>${esc(x.team || "")}</td>` : ""}${hasTime ? `<td class="time">${esc(x.time || "")}</td>` : ""}</tr>`).join("") +
    `</tbody></table></div>` +
    `<div class="note">${esc(r.classification)}. ` +
    `${partial ? `Classement partiel : la source ne publie que le top ${r.rows.length}.` : `${r.rows.length} coureurs classés.`}</div>` +
    `<footer>Source : <a href="${esc(r.url)}" rel="noopener">${esc(r.source)}, « ${esc(r.title)} »</a>, récupéré le ${esc(fmt(r.fetched))}. ` +
    `Pour les courses qui existent en version masculine et féminine, la page peut correspondre à la course masculine.</footer>`;
}
main().catch(e => { document.getElementById("card").innerHTML = `<p class="msg">Erreur : ${esc(e.message)}. Lance le site avec : py -m http.server 8000</p>`; });
</script>
</body>
</html>