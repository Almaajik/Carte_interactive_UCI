create table if not exists public.race_events (
  slug text primary key,
  name text not null,
  race_date date not null,
  country text not null,
  settled_at timestamptz
);

create table if not exists public.daily_races (
  race_date date primary key,
  race_slug text not null references public.race_events (slug),
  settled_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.rider_scores (
  rider_id text primary key,
  rider_name text not null,
  score integer not null check (score >= 0),
  profile text not null
);

create table if not exists public.race_entries (
  race_date date not null references public.daily_races (race_date) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  display_name text not null,
  rider_ids text[] not null check (cardinality(rider_ids) = 5),
  score integer not null check (score >= 0),
  updated_at timestamptz not null default now(),
  primary key (race_date, user_id)
);

create table if not exists public.race_mail (
  id uuid primary key default gen_random_uuid(),
  race_date date not null references public.daily_races (race_date) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  body text not null,
  drops_reward integer not null default 0 check (drops_reward >= 0),
  boosters_reward integer not null default 0 check (boosters_reward >= 0),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (race_date, user_id)
);

alter table public.user_collections
  alter column payload set default '{"riders":{},"drops":0,"boosterTokens":0,"freeDate":"","packsOpened":0,"lastPack":[]}'::jsonb;

alter table public.race_events enable row level security;
alter table public.daily_races enable row level security;
alter table public.rider_scores enable row level security;
alter table public.race_entries enable row level security;
alter table public.race_mail enable row level security;

revoke all on public.race_events, public.daily_races, public.rider_scores, public.race_entries, public.race_mail from anon, authenticated;
grant select on public.race_events, public.rider_scores to anon, authenticated;
grant select on public.daily_races to anon, authenticated;
grant select on public.race_entries to authenticated;
grant select on public.race_mail to authenticated;

drop policy if exists "Race calendar is public" on public.race_events;
create policy "Race calendar is public" on public.race_events for select to anon, authenticated using (true);

drop policy if exists "Daily race selection is public" on public.daily_races;
create policy "Daily race selection is public" on public.daily_races for select to anon, authenticated using (true);

drop policy if exists "Rider scores are public" on public.rider_scores;
create policy "Rider scores are public" on public.rider_scores for select to anon, authenticated using (true);

drop policy if exists "Race standings are visible to signed-in users" on public.race_entries;
create policy "Race standings are visible to signed-in users"
  on public.race_entries for select to authenticated using (true);

drop policy if exists "Users can read their own race mail" on public.race_mail;
create policy "Users can read their own race mail"
  on public.race_mail for select to authenticated using ((select auth.uid()) = user_id);

create or replace function public.get_daily_race()
returns table (race_date date, race_slug text, name text, country text, edition_date date)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := timezone('Europe/Paris', now())::date;
  v_race_slug text;
begin
  select events.slug into v_race_slug
    from public.race_events as events
    order by random()
    limit 1;
  if v_race_slug is null then
    raise exception 'Le calendrier des courses est vide.';
  end if;
  insert into public.daily_races (race_date, race_slug)
    values (v_today, v_race_slug)
    on conflict on constraint daily_races_pkey do nothing;
  return query
    select daily.race_date, events.slug, events.name, events.country, events.race_date
    from public.daily_races as daily
    join public.race_events as events on events.slug = daily.race_slug
    where daily.race_date = v_today;
end;
$$;

create or replace function public.register_race_team(p_race_date date, p_rider_ids text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := timezone('Europe/Paris', now())::date;
  v_race public.daily_races%rowtype;
  v_collection jsonb;
  v_owned_count integer;
  v_score_count integer;
  v_score integer;
  v_display_name text;
  v_opens timestamptz;
  v_closes timestamptz;
begin
  if v_user_id is null then
    raise exception 'Connecte-toi pour inscrire une équipe.';
  end if;
  if p_rider_ids is null or cardinality(p_rider_ids) <> 5
     or (select count(distinct rider_id) from unnest(p_rider_ids) as submitted(rider_id)) <> 5
     or exists (select 1 from unnest(p_rider_ids) as submitted(rider_id)
                where rider_id is null or length(rider_id) > 160) then
    raise exception 'Une équipe doit contenir exactement 5 cartes distinctes.';
  end if;
  if p_race_date is distinct from v_today then
    raise exception 'Seule la course du jour accepte les inscriptions.';
  end if;
  select * into v_race from public.daily_races where daily_races.race_date = p_race_date;
  if not found then
    raise exception 'La course du jour n’est pas encore sélectionnée.';
  end if;
  v_opens := (p_race_date + time '00:00') at time zone 'Europe/Paris';
  v_closes := (p_race_date + time '19:55') at time zone 'Europe/Paris';
  if now() < v_opens or now() >= v_closes then
    raise exception 'Les inscriptions sont ouvertes de 0 h à 19 h 55, heure de Paris, le jour de la course.';
  end if;
  select payload into v_collection from public.user_collections
    where user_id = v_user_id for update;
  if not found then
    raise exception 'Ta collection doit être synchronisée avant de participer.';
  end if;
  select count(*) into v_owned_count
    from unnest(p_rider_ids) as submitted(rider_id)
    where coalesce(v_collection->'riders', '{}'::jsonb) ? submitted.rider_id;
  if v_owned_count <> 5 then
    raise exception 'Tu ne possèdes pas toutes les cartes sélectionnées.';
  end if;
  select count(scores.rider_id), coalesce(sum(scores.score), 0)::integer into v_score_count, v_score
    from unnest(p_rider_ids) as submitted(rider_id)
    left join public.rider_scores as scores using (rider_id);
  if v_score_count <> 5 then
    raise exception 'Impossible de vérifier le score de cette équipe.';
  end if;
  select coalesce(username, 'Cycliste') into v_display_name
    from public.profiles where user_id = v_user_id;
  v_display_name := coalesce(v_display_name, 'Cycliste');
  insert into public.race_entries (race_date, user_id, display_name, rider_ids, score, updated_at)
    values (p_race_date, v_user_id, v_display_name, p_rider_ids, v_score, now())
    on conflict (race_date, user_id) do update
      set display_name = excluded.display_name, rider_ids = excluded.rider_ids,
          score = excluded.score, updated_at = excluded.updated_at;
end;
$$;

create or replace function public.settle_race(p_race_date date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_race public.daily_races%rowtype;
  v_race_name text;
  v_entry record;
  v_boosters integer;
  v_award_total integer;
begin
  select * into v_race from public.daily_races where race_date = p_race_date for update;
  if not found or v_race.settled_at is not null then
    return;
  end if;
  if now() < (v_race.race_date + time '20:00') at time zone 'Europe/Paris' then
    return;
  end if;
  select events.name into v_race_name
    from public.race_events as events where events.slug = v_race.race_slug;
  for v_entry in
    with standings as (
      select user_id, score,
        rank() over (order by score desc)::integer as place,
        count(*) over (partition by score)::integer as tied,
        row_number() over (partition by score order by user_id)::integer as tie_order
      from public.race_entries where race_date = p_race_date
    )
    select user_id, place, tied, tie_order,
      coalesce((
        select sum(case slots.place_slot when 1 then 3 when 2 then 2 when 3 then 1 else 0 end)::integer
        from generate_series(standings.place, standings.place + standings.tied - 1) as slots(place_slot)
      ), 0) as shared_boosters
    from standings
  loop
    v_award_total := v_entry.shared_boosters;
    v_boosters := v_award_total / v_entry.tied
      + case when v_entry.tie_order <= mod(v_award_total, v_entry.tied) then 1 else 0 end;
    insert into public.race_mail
      (race_date, user_id, title, body, drops_reward, boosters_reward)
    values (
      p_race_date, v_entry.user_id,
      'Résultat · ' || v_race_name,
      case when v_entry.place = 1 then '1re place'
        when v_entry.place = 2 then '2e place'
        when v_entry.place = 3 then '3e place'
        else v_entry.place::text || 'e place' end
        || case when v_entry.tied > 1 then
          ' · Égalité entre ' || v_entry.tied || ' équipes; les boosters des places concernées sont partagés.'
          else '' end,
      20, v_boosters
    )
    on conflict (race_date, user_id) do nothing;
  end loop;
  update public.daily_races set settled_at = now() where race_date = p_race_date;
end;
$$;

create or replace function public.settle_due_races()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_race_date date;
begin
  if auth.uid() is null then
    raise exception 'Connecte-toi pour mettre à jour les résultats.';
  end if;
  for v_race_date in
    select daily.race_date from public.daily_races as daily
    where daily.settled_at is null
      and (daily.race_date + time '20:00') at time zone 'Europe/Paris' <= now()
      and exists (select 1 from public.race_entries where race_date = daily.race_date)
    order by daily.race_date
  loop
    perform public.settle_race(v_race_date);
  end loop;
end;
$$;

create or replace function public.claim_race_reward(p_mail_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_mail public.race_mail%rowtype;
begin
  if v_user_id is null then
    raise exception 'Connecte-toi pour réclamer une récompense.';
  end if;
  select * into v_mail from public.race_mail
    where id = p_mail_id and user_id = v_user_id for update;
  if not found then
    raise exception 'Cette récompense est introuvable.';
  end if;
  if v_mail.claimed_at is not null then
    raise exception 'Cette récompense a déjà été réclamée.';
  end if;
  update public.user_collections
    set payload = jsonb_set(
      jsonb_set(
        jsonb_set(coalesce(payload, '{}'::jsonb) - 'dust', '{drops}',
          to_jsonb(coalesce((payload->>'drops')::integer, 0) + v_mail.drops_reward), true),
        '{boosterTokens}', to_jsonb(coalesce((payload->>'boosterTokens')::integer, 0) + v_mail.boosters_reward), true
      ),
      '{riders}', coalesce(payload->'riders', '{}'::jsonb), true
    ),
    updated_at = now()
    where user_id = v_user_id;
  if not found then
    raise exception 'Ta collection est introuvable.';
  end if;
  update public.race_mail set claimed_at = now() where id = p_mail_id;
end;
$$;

revoke all on function public.get_daily_race() from public, anon, authenticated;
revoke all on function public.register_race_team(date, text[]) from public, anon, authenticated;
revoke all on function public.settle_race(date) from public, anon, authenticated;
revoke all on function public.settle_due_races() from public, anon, authenticated;
revoke all on function public.claim_race_reward(uuid) from public, anon, authenticated;
grant execute on function public.get_daily_race() to anon, authenticated;
grant execute on function public.register_race_team(date, text[]) to authenticated;
grant execute on function public.settle_due_races() to authenticated;
grant execute on function public.claim_race_reward(uuid) to authenticated;

-- Seed data is generated from data/races.json and data/results/.
insert into public.race_events (slug, name, race_date, country) values
  ('tour-down-under-2026-01-17-australia', 'Tour Down Under', '2026-01-17', 'Australia'),
  ('tour-el-salvador-2026-01-17-el-salvador', 'Tour El Salvador', '2026-01-17', 'El Salvador'),
  ('tour-down-under-2026-01-20-australia', 'Tour Down Under', '2026-01-20', 'Australia'),
  ('tour-down-under-women-s-race-2026-01-21-australia', 'Tour Down Under Women''s Race', '2026-01-21', 'Australia'),
  ('classica-camp-de-morvedre-2026-01-23-spain', 'Classica Camp de Morvedre', '2026-01-23', 'Spain'),
  ('gp-castellon-ruta-de-la-ceramica-2026-01-24-spain', 'GP Castellón - Ruta de la Cerámica', '2026-01-24', 'Spain'),
  ('trofeo-marratxi-felanitx-2026-01-24-spain', 'Trofeo Marratxi - Felanitx', '2026-01-24', 'Spain'),
  ('clasica-comunitat-valenciana-2026-01-25-spain', 'Clàsica Comunitat Valenciana', '2026-01-25', 'Spain'),
  ('trofeo-palma-feminina-2026-01-25-spain', 'Trofeo Palma Feminina', '2026-01-25', 'Spain'),
  ('trofeo-binissalem-andratx-2026-01-26-spain', 'Trofeo Binissalem - Andratx', '2026-01-26', 'Spain'),
  ('al-ula-tour-2026-01-27-saudi-arabia', 'Al Ula Tour', '2026-01-27', 'Saudi Arabia'),
  ('trofeo-calvia-2026-01-28-spain', 'Trofeo Calvià', '2026-01-28', 'Spain'),
  ('trofeo-ses-salines-2026-01-29-spain', 'Trofeo Ses Salines', '2026-01-29', 'Spain'),
  ('trofeo-serra-tramuntana-2026-01-30-spain', 'Trofeo Serra Tramuntana', '2026-01-30', 'Spain'),
  ('cadel-evans-great-ocean-road-race-2026-01-31-australia', 'Cadel Evans Great Ocean Road Race', '2026-01-31', 'Australia'),
  ('trofeo-andratx-pollenca-2026-01-31-spain', 'Trofeo Andratx - Pollença', '2026-01-31', 'Spain'),
  ('cadel-evans-great-ocean-road-race-2026-02-01-australia', 'Cadel Evans Great Ocean Road Race', '2026-02-01', 'Australia'),
  ('gp-la-marseillaise-2026-02-01-france', 'GP La Marseillaise', '2026-02-01', 'France'),
  ('pionera-race-2026-02-01-spain', 'Pionera Race', '2026-02-01', 'Spain'),
  ('trofeo-palma-2026-02-01-spain', 'Trofeo Palma', '2026-02-01', 'Spain'),
  ('etoile-de-besseges-2026-02-04-france', 'Etoile de Bessèges', '2026-02-04', 'France'),
  ('volta-comunitat-valenciana-2026-02-04-spain', 'Volta Comunitat Valenciana', '2026-02-04', 'Spain'),
  ('uae-tour-women-2026-02-05-united-arab-emirates', 'UAE Tour Women', '2026-02-05', 'United Arab Emirates'),
  ('muscat-classic-2026-02-06-oman', 'Muscat Classic', '2026-02-06', 'Oman'),
  ('tour-of-oman-2026-02-07-oman', 'Tour of Oman', '2026-02-07', 'Oman'),
  ('aveiro-fegion-champions-classic-2026-02-08-portugal', 'Aveiro Fegion Champions Classic', '2026-02-08', 'Portugal'),
  ('trofeo-oro-in-euro-2026-02-08-italy', 'Trofeo Oro in Euro', '2026-02-08', 'Italy'),
  ('vuelta-cv-feminas-2026-02-08-spain', 'Vuelta CV Feminas', '2026-02-08', 'Spain'),
  ('setmana-volta-femenina-comunitat-valenciana-2026-02-12-spain', 'Setmana Volta Femenina Comunitat Valenciana', '2026-02-12', 'Spain'),
  ('tour-de-la-provence-2026-02-13-france', 'Tour de La Provence', '2026-02-13', 'France'),
  ('vuelta-a-murcia-2026-02-13-spain', 'Vuelta a Murcia', '2026-02-13', 'Spain'),
  ('figueira-champions-classic-2026-02-14-portugal', 'Figueira Champions Classic', '2026-02-14', 'Portugal'),
  ('clasica-de-almeria-2026-02-15-spain', 'Clasica de Almeria', '2026-02-15', 'Spain'),
  ('clasica-jaen-2026-02-16-spain', 'Clásica Jaén', '2026-02-16', 'Spain'),
  ('uae-tour-2026-02-16-united-arab-emirates', 'UAE Tour', '2026-02-16', 'United Arab Emirates'),
  ('volta-ao-algarve-2026-02-18-portugal', 'Volta ao Algarve', '2026-02-18', 'Portugal'),
  ('vuelta-a-andalucia-ruta-del-sol-2026-02-18-spain', 'Vuelta a Andalucia - Ruta del Sol', '2026-02-18', 'Spain'),
  ('classic-var-2026-02-21-france', 'Classic Var', '2026-02-21', 'France'),
  ('classica-de-almeria-2026-02-22-spain', 'Classica de Almeria', '2026-02-22', 'Spain'),
  ('midwest-cycling-classic-2026-02-22-belgium', 'Midwest Cycling Classic', '2026-02-22', 'Belgium'),
  ('tour-des-alpes-maritimes-2026-02-22-france', 'Tour des Alpes-Maritimes', '2026-02-22', 'France'),
  ('tour-du-rwanda-2026-02-22-rwanda', 'Tour du Rwanda', '2026-02-22', 'Rwanda'),
  ('giro-di-sardegna-2026-02-25-italy', 'Giro di Sardegna', '2026-02-25', 'Italy'),
  ('faun-ardeche-classic-2026-02-28-france', 'Faun Ardèche Classic', '2026-02-28', 'France'),
  ('omloop-nieuwsblad-2026-02-28-belgium', 'Omloop Nieuwsblad', '2026-02-28', 'Belgium'),
  ('visit-south-aegean-gp-2026-02-28-greece', 'Visit South Aegean GP', '2026-02-28', 'Greece'),
  ('faun-drome-classic-2026-03-01-france', 'Faun Drôme Classic', '2026-03-01', 'France'),
  ('kuurne-brussels-kuurne-2026-03-01-belgium', 'Kuurne-Brussels-Kuurne', '2026-03-01', 'Belgium'),
  ('omloop-van-het-hageland-2026-03-01-belgium', 'Omloop Van Het Hageland', '2026-03-01', 'Belgium'),
  ('region-on-dodecanese-gp-2026-03-01-greece', 'Region On Dodecanese GP', '2026-03-01', 'Greece'),
  ('le-samyn-des-dames-2026-03-02-belgium', 'Le Samyn des Dames', '2026-03-02', 'Belgium'),
  ('le-samyn-2026-03-03-belgium', 'Le Samyn', '2026-03-03', 'Belgium'),
  ('trofeo-laigueglia-2026-03-04-italy', 'Trofeo Laigueglia', '2026-03-04', 'Italy'),
  ('vuelta-a-extremadura-femenina-2026-03-06-spain', 'Vuelta a Extremadura Femenina', '2026-03-06', 'Spain'),
  ('strade-bianche-2026-03-07-italy', 'Strade Bianche', '2026-03-07', 'Italy'),
  ('paris-nice-2026-03-08-france', 'Paris-Nice', '2026-03-08', 'France'),
  ('tirreno-adriatico-2026-03-09-italy', 'Tirreno-Adriatico', '2026-03-09', 'Italy'),
  ('ixina-leeuw-oetingen-2026-03-11-belgium', 'Ixina Leeuw-Oetingen', '2026-03-11', 'Belgium'),
  ('tour-de-taiwan-2026-03-15-taiwan', 'Tour de Taiwan', '2026-03-15', 'Taiwan'),
  ('trofeo-alfredo-binda-2026-03-15-italy', 'Trofeo Alfredo Binda', '2026-03-15', 'Italy'),
  ('milano-torino-2026-03-18-italy', 'Milano-Torino', '2026-03-18', 'Italy'),
  ('noekere-koerse-2026-03-18-belgium', 'Noekere Koerse', '2026-03-18', 'Belgium'),
  ('nokere-koerse-2026-03-18-belgium', 'Nokere Koerse', '2026-03-18', 'Belgium'),
  ('gp-de-denain-2026-03-19-france', 'GP de Denain', '2026-03-19', 'France'),
  ('koksijde-classic-2026-03-20-belgium', 'Koksijde Classic', '2026-03-20', 'Belgium'),
  ('milano-sanremo-2026-03-21-italy', 'Milano-Sanremo', '2026-03-21', 'Italy'),
  ('milano-sanremo-donne-2026-03-21-italy', 'Milano-Sanremo Donne', '2026-03-21', 'Italy'),
  ('gp-jean-pierre-monsere-2026-03-22-belgium', 'GP Jean-Pierre Monseré', '2026-03-22', 'Belgium'),
  ('volta-a-catalunya-2026-03-23-spain', 'Volta a Catalunya', '2026-03-23', 'Spain'),
  ('princess-maha-chakri-sirindhorn-s-cup-tour-of-thailand-2026-03-24-thailand', 'Princess Maha Chakri Sirindhorn''s Cup Tour of Thailand', '2026-03-24', 'Thailand'),
  ('ronde-van-brugge-2026-03-25-belgium', 'Ronde Van Brugge', '2026-03-25', 'Belgium'),
  ('settimana-coppi-e-bartali-2026-03-25-italy', 'Settimana Coppi e Bartali', '2026-03-25', 'Italy'),
  ('ronde-van-brugge-2026-03-26-belgium', 'Ronde Van Brugge', '2026-03-26', 'Belgium'),
  ('e3-saxo-classic-2026-03-27-belgium', 'E3 Saxo Classic', '2026-03-27', 'Belgium'),
  ('gp-emilia-2026-03-29-italy', 'GP Emilia', '2026-03-29', 'Italy'),
  ('gent-wevelgem-2026-03-29-belgium', 'Gent-Wevelgem', '2026-03-29', 'Belgium'),
  ('la-roue-tourangelle-2026-03-29-france', 'La Roue Tourangelle', '2026-03-29', 'France'),
  ('paris-camembert-2026-03-31-france', 'Paris-Camembert', '2026-03-31', 'France'),
  ('princess-maha-chakri-sirindhorn-s-cup-women-s-tour-of-thailand-2026-03-31-thailand', 'Princess Maha Chakri Sirindhorn''s Cup Women''s Tour of Thailand', '2026-03-31', 'Thailand'),
  ('dwars-door-vlaanderen-2026-04-01-belgium', 'Dwars Door Vlaanderen', '2026-04-01', 'Belgium'),
  ('la-route-adelie-de-vitre-2026-04-03-france', 'La Route Adélie de Vitré', '2026-04-03', 'France'),
  ('gp-miguel-indurain-2026-04-04-spain', 'GP Miguel Indurain', '2026-04-04', 'Spain'),
  ('nxt-classic-2026-04-04-netherlands', 'NXT Classic', '2026-04-04', 'Netherlands'),
  ('ronde-van-vlaanderen-2026-04-05-belgium', 'Ronde Van Vlaanderen', '2026-04-05', 'Belgium'),
  ('itzulia-basque-country-2026-04-06-spain', 'Itzulia Basque Country', '2026-04-06', 'Spain'),
  ('ronde-de-mouscron-2026-04-06-belgium', 'Ronde de Mouscron', '2026-04-06', 'Belgium'),
  ('region-pays-de-la-loire-tour-2026-04-07-france', 'Région Pays de La Loire Tour', '2026-04-07', 'France'),
  ('region-pays-de-la-loire-tour-feminin-2026-04-08-france', 'Région Pays de la Loire Tour Féminin', '2026-04-08', 'France'),
  ('scheldeprijs-2026-04-08-belgium', 'Scheldeprijs', '2026-04-08', 'Belgium'),
  ('paris-roubaix-2026-04-12-france', 'Paris-Roubaix', '2026-04-12', 'France'),
  ('o-gran-camino-2026-04-14-spain', 'O Gran Camiño', '2026-04-14', 'Spain'),
  ('ronde-van-limburg-2026-04-15-belgium', 'Ronde Van Limburg', '2026-04-15', 'Belgium'),
  ('tour-of-hainan-2026-04-15-china', 'Tour of Hainan', '2026-04-15', 'China'),
  ('brabantse-pijl-2026-04-17-belgium', 'Brabantse Pijl', '2026-04-17', 'Belgium'),
  ('classic-grand-bescancon-doubs-2026-04-17-france', 'Classic Grand Bescançon Doubs', '2026-04-17', 'France'),
  ('tour-du-jura-2026-04-18-france', 'Tour du Jura', '2026-04-18', 'France'),
  ('amstel-gold-race-2026-04-19-netherlands', 'Amstel Gold Race', '2026-04-19', 'Netherlands'),
  ('gp-feminin-de-chambery-2026-04-19-france', 'GP Féminin de Chambéry', '2026-04-19', 'France'),
  ('tour-of-the-alps-2026-04-20-italy', 'Tour of the Alps', '2026-04-20', 'Italy'),
  ('la-fleche-wallonne-2026-04-22-belgium', 'La Flèche Wallonne', '2026-04-22', 'Belgium'),
  ('vuelta-asturias-2026-04-23-spain', 'Vuelta Asturias', '2026-04-23', 'Spain'),
  ('omloop-van-borsele-women-2026-04-25-belgium', 'Omloop Van Borsele Women', '2026-04-25', 'Belgium'),
  ('gp-della-liberazione-donne-2026-04-26-italy', 'GP della Liberazione Donne', '2026-04-26', 'Italy'),
  ('liege-bastogne-liege-2026-04-26-belgium', 'Liège-Bastogne-Liège', '2026-04-26', 'Belgium'),
  ('tour-of-turkiye-2026-04-26-turkiye', 'Tour of Türkiye', '2026-04-26', 'Türkiye'),
  ('tour-de-romandie-2026-04-28-switzerland', 'Tour de Romandie', '2026-04-28', 'Switzerland'),
  ('eschborn-frankfurt-2026-05-01-germany', 'Eschborn-Frankfurt', '2026-05-01', 'Germany'),
  ('gp-anicolor-2026-05-01-portugal', 'GP Anicolor', '2026-05-01', 'Portugal'),
  ('gp-immo-zone-vloer-en-chapewerken-2026-05-01-belgium', 'GP Immo Zone Vloer-en-Chapewerken', '2026-05-01', 'Belgium'),
  ('festival-elsy-jacobs-2026-05-02-luxembourg', 'Festival Elsy Jacobs', '2026-05-02', 'Luxembourg'),
  ('famenne-ardenne-classic-2026-05-03-belgium', 'Famenne Ardenne Classic', '2026-05-03', 'Belgium'),
  ('festival-elsy-jacobs-2026-05-03-luxembourg', 'Festival Elsy Jacobs', '2026-05-03', 'Luxembourg'),
  ('giro-dell-appennino-2026-05-03-italy', 'Giro dell''Appennino', '2026-05-03', 'Italy'),
  ('vuelta-espana-femenina-2026-05-03-spain', 'Vuelta España Femenina', '2026-05-03', 'Spain'),
  ('tour-of-hellas-2026-05-06-greece', 'Tour of Hellas', '2026-05-06', 'Greece'),
  ('giro-d-italia-2026-05-08-italy', 'Giro d''Italia', '2026-05-08', 'Italy'),
  ('la-classique-morbihan-2026-05-08-france', 'La Classique Morbihan', '2026-05-08', 'France'),
  ('gp-du-morbihan-2026-05-09-france', 'GP du Morbihan', '2026-05-09', 'France'),
  ('gp-du-morbihan-femmes-2026-05-09-france', 'GP du Morbihan Femmes', '2026-05-09', 'France'),
  ('baku-khankendi-azerbaijan-2026-05-10-azerbaijan', 'Baku-Khankendi Azerbaijan', '2026-05-10', 'Azerbaijan'),
  ('tro-bro-leon-2026-05-10-france', 'Tro-Bro Léon', '2026-05-10', 'France'),
  ('trofee-maarten-wynants-2026-05-10-belgium', 'Trofee Maarten Wynants', '2026-05-10', 'Belgium'),
  ('navaraa-women-s-classic-2026-05-12-spain', 'Navaraa Women''s Classic', '2026-05-12', 'Spain'),
  ('fleche-du-sud-2026-05-13-luxembourg', 'Flèche du Sud', '2026-05-13', 'Luxembourg'),
  ('tour-de-hongrie-2026-05-13-hungary', 'Tour de Hongrie', '2026-05-13', 'Hungary'),
  ('circuit-de-wallonie-2026-05-14-belgium', 'Circuit de Wallonie', '2026-05-14', 'Belgium'),
  ('itzulia-women-2026-05-15-spain', 'Itzulia Women', '2026-05-15', 'Spain'),
  ('omloop-der-kempen-ladies-2026-05-16-belgium', 'Omloop Der Kempen Ladies', '2026-05-16', 'Belgium'),
  ('tour-du-finistere-2026-05-16-france', 'Tour du Finistère', '2026-05-16', 'France'),
  ('boucles-de-l-aulne-2026-05-17-france', 'Boucles de l''Aulne', '2026-05-17', 'France'),
  ('rund-um-koln-2026-05-17-germany', 'Rund um Köln', '2026-05-17', 'Germany'),
  ('classique-dunkerque-2026-05-19-france', 'Classique Dunkerque', '2026-05-19', 'France'),
  ('emakumeen-saria-2026-05-19-spain', 'Emakumeen Saria', '2026-05-19', 'Spain'),
  ('4-jours-de-dunkerque-2026-05-20-france', '4 Jours de Dunkerque', '2026-05-20', 'France'),
  ('gp-beiras-e-serra-da-estrela-2026-05-20-portugal', 'GP Beiras e Serra da Estrela', '2026-05-20', 'Portugal'),
  ('vuelta-a-burgos-feminas-2026-05-21-spain', 'Vuelta a Burgos Feminas', '2026-05-21', 'Spain'),
  ('veenendaal-veenendaal-2026-05-22-netherlands', 'Veenendaal-Veenendaal', '2026-05-22', 'Netherlands'),
  ('veenendaal-veenendaal-2026-05-23-netherlands', 'Veenendaal-Veenendaal', '2026-05-23', 'Netherlands'),
  ('antwerp-port-epic-ladies-2026-05-24-belgium', 'Antwerp Port Epic Ladies', '2026-05-24', 'Belgium'),
  ('gp-criquelion-2026-05-24-belgium', 'GP Criquelion', '2026-05-24', 'Belgium'),
  ('antwerp-port-epic-sels-trophy-2026-05-25-belgium', 'Antwerp Port Epic - Sels Trophy', '2026-05-25', 'Belgium'),
  ('gp-mazda-2026-05-25-belgium', 'GP Mazda', '2026-05-25', 'Belgium'),
  ('boucles-de-la-mayenne-2026-05-28-france', 'Boucles de la Mayenne', '2026-05-28', 'France'),
  ('bretagne-ladies-tour-2026-05-28-france', 'Bretagne Ladies Tour', '2026-05-28', 'France'),
  ('giro-d-italia-women-2026-05-30-italy', 'Giro d''Italia Women', '2026-05-30', 'Italy'),
  ('gp-ciudad-de-eibar-2026-05-31-spain', 'GP Ciudad de Eibar', '2026-05-31', 'Spain'),
  ('tour-de-wallonie-2026-06-01-belgium', 'Tour de Wallonie', '2026-06-01', 'Belgium'),
  ('mercan-tour-classic-alpes-maritimes-2026-06-03-france', 'Mercan''tour Classic Alpes-Maritimes', '2026-06-03', 'France'),
  ('tour-of-estonia-2026-06-04-estonia', 'Tour of Estonia', '2026-06-04', 'Estonia'),
  ('heistse-pijl-2026-06-06-belgium', 'Heistse Pijl', '2026-06-06', 'Belgium'),
  ('alpes-gresivaudan-classic-2026-06-07-france', 'Alpes Grésivaudan Classic', '2026-06-07', 'France'),
  ('brussels-cycling-classic-2026-06-07-belgium', 'Brussels Cycling Classic', '2026-06-07', 'Belgium'),
  ('dwars-door-de-westhoek-2026-06-07-belgium', 'Dwars Door De Westhoek', '2026-06-07', 'Belgium'),
  ('tour-auvergne-rhone-alpes-2026-06-07-france', 'Tour Auvergne-Rhône-Alpes', '2026-06-07', 'France'),
  ('circuit-franco-belge-2026-06-10-belgium', 'Circuit Franco-Belge', '2026-06-10', 'Belgium'),
  ('tour-feminin-international-des-pyrenees-2026-06-12-france', 'Tour Féminin International des Pyrénées', '2026-06-12', 'France'),
  ('copenhagen-sprint-2026-06-13-denmark', 'Copenhagen Sprint', '2026-06-13', 'Denmark'),
  ('dwars-door-het-hageland-2026-06-13-belgium', 'Dwars Door Het Hageland', '2026-06-13', 'Belgium'),
  ('copenhagen-sprint-2026-06-14-denmark', 'Copenhagen Sprint', '2026-06-14', 'Denmark'),
  ('elfstedenronde-2026-06-14-belgium', 'Elfstedenronde', '2026-06-14', 'Belgium'),
  ('flanders-diamond-tour-2026-06-14-belgium', 'Flanders Diamond Tour', '2026-06-14', 'Belgium'),
  ('baloise-belgium-tour-2026-06-17-belgium', 'Baloise Belgium Tour', '2026-06-17', 'Belgium'),
  ('tour-de-suisse-2026-06-17-switzerland', 'Tour de Suisse', '2026-06-17', 'Switzerland'),
  ('tour-de-suisse-women-2026-06-17-switzerland', 'Tour de Suisse Women', '2026-06-17', 'Switzerland'),
  ('tour-of-slovenia-2026-06-17-slovenia', 'Tour of Slovenia', '2026-06-17', 'Slovenia'),
  ('la-route-d-occitanie-2026-06-18-france', 'La Route d''Occitanie', '2026-06-18', 'France'),
  ('vuelta-a-catalunya-femenina-2026-06-19-spain', 'Vuelta a Catalunya Femenina', '2026-06-19', 'Spain'),
  ('andorra-classic-2026-06-21-andorra', 'Andorra Classic', '2026-06-21', 'Andorra'),
  ('women-cycling-day-2026-06-21-germany', 'Women Cycling Day', '2026-06-21', 'Germany'),
  ('sibiu-tour-2026-07-04-romania', 'Sibiu Tour', '2026-07-04', 'Romania'),
  ('tour-de-france-2026-07-04-france', 'Tour de France', '2026-07-04', 'France'),
  ('argenta-classic-deurne-2026-07-05-belgium', 'Argenta Classic - Deurne', '2026-07-05', 'Belgium'),
  ('tour-of-magnificent-qinghai-2026-07-05-china', 'Tour of Magnificent Qinghai', '2026-07-05', 'China'),
  ('tour-of-austria-2026-07-07-austria', 'Tour of Austria', '2026-07-07', 'Austria'),
  ('baloise-ladies-tour-2026-07-15-belgium', 'Baloise Ladies Tour', '2026-07-15', 'Belgium'),
  ('la-perigord-ladies-2026-07-18-france', 'La Périgord Ladies', '2026-07-18', 'France'),
  ('la-picto-en-nouvelle-aquitaine-2026-07-19-france', 'La Picto en Nouvelle-Aquitaine', '2026-07-19', 'France'),
  ('clasica-de-ordizia-2026-07-25-spain', 'Clásica de Ordizia', '2026-07-25', 'Spain'),
  ('clasica-castilla-y-leon-2026-07-26-spain', 'Clasica Castilla y Leon', '2026-07-26', 'Spain'),
  ('tour-de-l-ain-2026-07-28-france', 'Tour de l''Ain', '2026-07-28', 'France'),
  ('tour-of-denmark-2026-07-29-denmark', 'Tour of Denmark', '2026-07-29', 'Denmark'),
  ('donostia-san-sebastian-klasikoa-2026-08-01-spain', 'Donostia San Sebastian Klasikoa', '2026-08-01', 'Spain'),
  ('tour-de-france-femmes-2026-08-01-france', 'Tour de France Femmes', '2026-08-01', 'France'),
  ('china-xizang-trans-himalaya-2026-08-02-china', 'China Xizang Trans-Himalaya', '2026-08-02', 'China'),
  ('circuito-de-getxo-2026-08-02-spain', 'Circuito de Getxo', '2026-08-02', 'Spain'),
  ('tour-de-pologne-2026-08-03-poland', 'Tour de Pologne', '2026-08-03', 'Poland'),
  ('vuelta-a-burgos-2026-08-04-spain', 'Vuelta a Burgos', '2026-08-04', 'Spain'),
  ('volta-a-portugal-2026-08-05-portugal', 'Volta a Portugal', '2026-08-05', 'Portugal'),
  ('arctic-race-of-norway-2026-08-13-norway', 'Arctic Race of Norway', '2026-08-13', 'Norway'),
  ('czech-tour-2026-08-13-czechia', 'Czech Tour', '2026-08-13', 'Czechia'),
  ('tour-de-pologne-women-2026-08-14-poland', 'Tour de Pologne Women', '2026-08-14', 'Poland'),
  ('gp-yvonne-reynders-2026-08-15-belgium', 'GP Yvonne Reynders', '2026-08-15', 'Belgium'),
  ('adac-cyclassics-2026-08-16-germany', 'ADAC Cyclassics', '2026-08-16', 'Germany'),
  ('la-polynormande-2026-08-16-france', 'La Polynormande', '2026-08-16', 'France'),
  ('egmont-cycling-race-women-2026-08-18-belgium', 'Egmont Cycling Race Women', '2026-08-18', 'Belgium'),
  ('tour-du-limousin-2026-08-18-france', 'Tour du Limousin', '2026-08-18', 'France'),
  ('deutschland-tour-2026-08-19-germany', 'Deutschland Tour', '2026-08-19', 'Germany'),
  ('renewi-tour-2026-08-19-belgium', 'Renewi Tour', '2026-08-19', 'Belgium'),
  ('tour-of-britain-women-2026-08-19-united-kingdom', 'Tour of Britain Women', '2026-08-19', 'United Kingdom'),
  ('gp-lucien-van-impe-2026-08-20-belgium', 'GP Lucien Van Impe', '2026-08-20', 'Belgium'),
  ('konvert-kortrijk-koerse-2026-08-21-belgium', 'Konvert Kortrijk Koerse', '2026-08-21', 'Belgium'),
  ('vuelta-a-espana-2026-08-22-spain', 'Vuelta a España', '2026-08-22', 'Spain'),
  ('tour-du-poitou-charentes-en-nouvelle-aquitaine-2026-08-25-france', 'Tour du Poitou-Charentes en Nouvelle-Aquitaine', '2026-08-25', 'France'),
  ('muur-classic-geraardsbergen-2026-08-26-belgium', 'Muur Classic Geraardsbergen', '2026-08-26', 'Belgium'),
  ('kreiz-breizh-feminin-2026-08-27-france', 'Kreiz Breizh Féminin', '2026-08-27', 'France'),
  ('bretagne-classic-ouest-france-2026-08-30-france', 'Bretagne Classic - Ouest France', '2026-08-30', 'France'),
  ('gp-kranj-2026-08-30-slovenia', 'GP Kranj', '2026-08-30', 'Slovenia'),
  ('philadelphia-cycling-classic-2026-08-30-united-states', 'Philadelphia Cycling Classic', '2026-08-30', 'United States'),
  ('tour-de-korea-2026-08-31-south-korea', 'Tour de Korea', '2026-08-31', 'South Korea'),
  ('tour-of-britain-men-2026-09-02-united-kingdom', 'Tour of Britain Men', '2026-09-02', 'United Kingdom'),
  ('zlm-tour-2026-09-02-netherlands', 'ZLM Tour', '2026-09-02', 'Netherlands'),
  ('classic-lorient-agglomeration-2026-09-05-france', 'Classic Lorient Agglomération', '2026-09-05', 'France'),
  ('tout-commence-en-finistere-ladies-classic-2026-09-05-france', 'Tout Commence En Finistère Ladies Classic', '2026-09-05', 'France'),
  ('gp-industria-artigianato-2026-09-06-italy', 'GP Industria & Artigianato', '2026-09-06', 'Italy'),
  ('pointe-du-raz-ladies-classic-2026-09-06-france', 'Pointe du Raz Ladies Classic', '2026-09-06', 'France'),
  ('tour-of-binzhou-2026-09-08-china', 'Tour of Binzhou', '2026-09-08', 'China'),
  ('giro-della-toscana-memorial-alfredo-martini-2026-09-09-italy', 'Giro della Toscana - Memorial Alfredo Martini', '2026-09-09', 'Italy'),
  ('coppa-sabatini-2026-09-10-italy', 'Coppa Sabatini', '2026-09-10', 'Italy'),
  ('gp-de-quebec-2026-09-11-canada', 'GP de Québec', '2026-09-11', 'Canada'),
  ('a-travers-les-hauts-de-france-2026-09-12-france', 'A Travers Les Hauts de France', '2026-09-12', 'France'),
  ('boucles-drome-ardeche-femmes-2026-09-12-france', 'Boucles Drôme Ardèche Femmes', '2026-09-12', 'France'),
  ('memorial-marco-pantani-2026-09-12-italy', 'Memorial Marco Pantani', '2026-09-12', 'Italy'),
  ('tour-of-taihu-lake-2026-09-12-china', 'Tour of Taihu Lake', '2026-09-12', 'China'),
  ('gp-de-fourmies-la-voix-du-nord-2026-09-13-france', 'GP de Fourmies - La Voix du Nord', '2026-09-13', 'France'),
  ('gp-de-montreal-2026-09-13-canada', 'GP de Montréal', '2026-09-13', 'Canada'),
  ('la-choralis-fourmies-feminine-2026-09-13-france', 'La Choralis Fourmies Féminine', '2026-09-13', 'France'),
  ('trofeo-matteotti-2026-09-13-italy', 'Trofeo Matteotti', '2026-09-13', 'Italy'),
  ('women-s-cycling-gp-stuttgart-2026-09-13-germany', 'Women''s Cycling GP Stuttgart', '2026-09-13', 'Germany'),
  ('il-giro-d-abruzzo-2026-09-15-italy', 'Il Giro d''Abruzzo', '2026-09-15', 'Italy'),
  ('chrono-feminin-du-gatineau-2026-09-16-canada', 'Chrono Féminin du Gatineau', '2026-09-16', 'Canada'),
  ('gp-de-wallonie-2026-09-16-belgium', 'GP de Wallonie', '2026-09-16', 'Belgium'),
  ('gp-de-wallonie-dames-2026-09-16-belgium', 'GP de Wallonie Dames', '2026-09-16', 'Belgium'),
  ('okolo-slovenska-2026-09-16-slovakia', 'Okolo Slovenska', '2026-09-16', 'Slovakia'),
  ('tour-of-luxembourg-2026-09-16-luxembourg', 'Tour of Luxembourg', '2026-09-16', 'Luxembourg'),
  ('tour-du-gatineau-2026-09-17-canada', 'Tour du Gatineau', '2026-09-17', 'Canada'),
  ('kampioenscap-van-vlaanderen-2026-09-18-belgium', 'Kampioenscap Van Vlaanderen', '2026-09-18', 'Belgium'),
  ('tour-of-huangshan-2026-09-18-china', 'Tour of Huangshan', '2026-09-18', 'China'),
  ('gp-del-lazio-2026-09-19-italy', 'GP del Lazio', '2026-09-19', 'Italy'),
  ('super-8-classic-2026-09-19-belgium', 'Super 8 Classic', '2026-09-19', 'Belgium'),
  ('giro-della-romagna-2026-09-20-italy', 'Giro della Romagna', '2026-09-20', 'Italy'),
  ('gooikse-pijl-2026-09-20-belgium', 'Gooikse Pijl', '2026-09-20', 'Belgium'),
  ('world-championships-men-s-tt-2026-09-20-canada', 'World Championships: Men''s TT', '2026-09-20', 'Canada'),
  ('world-championships-women-s-tt-2026-09-20-canada', 'World Championships: Women''s TT', '2026-09-20', 'Canada'),
  ('world-championships-mixed-relay-tt-2026-09-22-canada', 'World Championships: Mixed Relay TT', '2026-09-22', 'Canada'),
  ('omloop-van-het-houtland-2026-09-23-belgium', 'Omloop Van Het Houtland', '2026-09-23', 'Belgium'),
  ('world-championships-women-s-road-race-2026-09-26-canada', 'World Championships: Women''s Road Race', '2026-09-26', 'Canada'),
  ('paris-chauny-2026-09-27-france', 'Paris-Chauny', '2026-09-27', 'France'),
  ('tour-de-langkawi-2026-09-27-malaysia', 'Tour de Langkawi', '2026-09-27', 'Malaysia'),
  ('world-championships-men-s-road-race-2026-09-27-canada', 'World Championships: Men''s Road Race', '2026-09-27', 'Canada'),
  ('cholet-agglo-tour-2026-10-03-france', 'Cholet Agglo Tour', '2026-10-03', 'France'),
  ('giro-dell-emilia-2026-10-03-italy', 'Giro dell''Emilia', '2026-10-03', 'Italy'),
  ('giro-dell-emilia-donne-2026-10-03-italy', 'Giro dell''Emilia Donne', '2026-10-03', 'Italy'),
  ('sparkassen-munsterland-giro-2026-10-03-germany', 'Sparkassen Münsterland Giro', '2026-10-03', 'Germany'),
  ('coppa-agostoni-2026-10-04-italy', 'Coppa Agostoni', '2026-10-04', 'Italy'),
  ('tour-de-vendee-2026-10-04-france', 'Tour de Vendée', '2026-10-04', 'France'),
  ('coppa-bernocchi-2026-10-05-italy', 'Coppa Bernocchi', '2026-10-05', 'Italy'),
  ('binche-chimay-binche-2026-10-06-belgium', 'Binche-Chimay-Binche', '2026-10-06', 'Belgium'),
  ('tre-valle-varesine-2026-10-06-italy', 'Tre Valle Varesine', '2026-10-06', 'Italy'),
  ('tre-valle-varesine-2026-10-06', 'Tre Valle Varesine', '2026-10-06', ''),
  ('gran-piemonte-2026-10-08-italy', 'Gran Piemonte', '2026-10-08', 'Italy'),
  ('tour-of-chongming-island-2026-10-09-china', 'Tour of Chongming Island', '2026-10-09', 'China'),
  ('il-lombardia-2026-10-10-italy', 'Il Lombardia', '2026-10-10', 'Italy'),
  ('tour-de-kyushu-2026-10-10-japan', 'Tour de Kyushu', '2026-10-10', 'Japan'),
  ('paris-tours-2026-10-11-france', 'Paris-Tours', '2026-10-11', 'France'),
  ('sun-hung-kai-hong-kong-cyclothon-2026-10-11-hong-kong', 'Sun Hung Kai Hong Kong Cyclothon', '2026-10-11', 'Hong Kong'),
  ('eneco-tour-2026-10-13-netherlands', 'Eneco Tour', '2026-10-13', 'Netherlands'),
  ('eneco-tour-women-2026-10-13-netherlands', 'Eneco Tour Women', '2026-10-13', 'Netherlands'),
  ('tour-of-guangxi-2026-10-13-china', 'Tour of Guangxi', '2026-10-13', 'China'),
  ('giro-del-veneto-2026-10-14-italy', 'Giro del Veneto', '2026-10-14', 'Italy'),
  ('veneto-women-2026-10-14-italy', 'Veneto Women', '2026-10-14', 'Italy'),
  ('chrono-des-nations-2026-10-18-france', 'Chrono des Nations', '2026-10-18', 'France'),
  ('utsunomiya-japan-cup-2026-10-18-japan', 'Utsunomiya Japan Cup', '2026-10-18', 'Japan'),
  ('veneto-classic-2026-10-18-italy', 'Veneto Classic', '2026-10-18', 'Italy')
on conflict (slug) do update set name = excluded.name, race_date = excluded.race_date, country = excluded.country;

insert into public.rider_scores (rider_id, rider_name, score, profile) values
  ('aaron gate-nzl', 'Aaron Gate', 1, 'Coureur de classiques'),
  ('abel balderstone-esp', 'Abel Balderstone', 38, 'Sp?cialiste du g?n?ral'),
  ('adam howell-gbr', 'Adam Howell', 4, 'Sp?cialiste du g?n?ral'),
  ('adam yates-gbr', 'Adam Yates', 63, 'Sp?cialiste du g?n?ral'),
  ('adria pericas-esp', 'Adrià Pericas', 21, 'Sp?cialiste du g?n?ral'),
  ('adrian cruces', 'Adrián Cruces', 0, 'Profil ? pr?ciser'),
  ('adrian fernandez', 'Adrián Fernández', 12, 'Coureur de classiques'),
  ('adrien boichis-fra', 'Adrien Boichis', 8, 'Sp?cialiste du g?n?ral'),
  ('afonso eulalio-por', 'Afonso Eulálio', 32, 'Sp?cialiste du g?n?ral'),
  ('aime de gendt-bel', 'Aimé De Gendt', 9, 'Coureur de classiques'),
  ('alan hatherly-rsa', 'Alan Hatherly', 18, 'Sp?cialiste du g?n?ral'),
  ('albert withen philipsen-den', 'Albert Withen Philipsen', 9, 'Sp?cialiste du g?n?ral'),
  ('alberto bettiol-ita', 'Alberto Bettiol', 13, 'Sp?cialiste du g?n?ral'),
  ('alec segaert-bel', 'Alec Segaert', 10, 'Sp?cialiste du g?n?ral'),
  ('aleksandr vlasov', 'Aleksandr Vlasov', 22, 'Sp?cialiste du g?n?ral'),
  ('alessandro borgo-ita', 'Alessandro Borgo', 9, 'Coureur de classiques'),
  ('alessandro covi-ita', 'Alessandro Covi', 15, 'Coureur de classiques'),
  ('alessandro fancellu-ita', 'Alessandro Fancellu', 93, 'Sp?cialiste du g?n?ral'),
  ('alessandro iacchi-ita', 'Alessandro Iacchi', 12, 'Sp?cialiste du g?n?ral'),
  ('alessandro pinarello-ita', 'Alessandro Pinarello', 38, 'Sp?cialiste du g?n?ral'),
  ('alessandro romele-ita', 'Alessandro Romele', 7, 'Coureur de classiques'),
  ('alessio delle vedove-ita', 'Alessio Delle Vedove', 14, 'Sp?cialiste du g?n?ral'),
  ('alessio magagnotti-ita', 'Alessio Magagnotti', 7, 'Coureur de classiques'),
  ('alessio martinelli-ita', 'Alessio Martinelli', 4, 'Sp?cialiste du g?n?ral'),
  ('alex aranburu-esp', 'Alex Aranburu', 62, 'Sp?cialiste du g?n?ral'),
  ('alex baudin-fra', 'Alex Baudin', 25, 'Sp?cialiste du g?n?ral'),
  ('alex molenaar-ned', 'Alex Molenaar', 1, 'Coureur de classiques'),
  ('alex tolio-ita', 'Alex Tolio', 22, 'Sp?cialiste du g?n?ral'),
  ('alexander kamp-den', 'Alexander Kamp', 36, 'Sp?cialiste du g?n?ral'),
  ('alexandre balmer-sui', 'Alexandre Balmer', 18, 'Sp?cialiste du g?n?ral'),
  ('alexandre delettre-fra', 'Alexandre Delettre', 32, 'Sp?cialiste du g?n?ral'),
  ('alexis guerin-fra', 'Alexis Guérin', 30, 'Sp?cialiste du g?n?ral'),
  ('alexis renard-fra', 'Alexis Renard', 17, 'Coureur de classiques'),
  ('ally wollaston-nzl', 'Ally Wollaston', 8, 'Coureur de classiques'),
  ('alvaro carpe', 'Álvaro Carpe', 14, 'Coureur de classiques'),
  ('amanda spratt', 'Amanda Spratt', 0, 'Profil ? pr?ciser'),
  ('amanda spratt-aus', 'Amanda Spratt', 8, 'Sp?cialiste du g?n?ral'),
  ('ana vitoria magalhaes', 'Ana Vitória Magalhães', 0, 'Profil ? pr?ciser'),
  ('anders foldager-den', 'Anders Foldager', 41, 'Sp?cialiste du g?n?ral'),
  ('andrea bagioli-ita', 'Andrea Bagioli', 12, 'Coureur de classiques'),
  ('andrea raccagni noviero-ita', 'Andrea Raccagni Noviero', 20, 'Sp?cialiste du g?n?ral'),
  ('andrea raccagni-ita', 'Andrea Raccagni', 14, 'Sp?cialiste du g?n?ral'),
  ('andrea vendrame-ita', 'Andrea Vendrame', 10, 'Coureur de classiques'),
  ('andreas kron-den', 'Andreas Kron', 27, 'Sp?cialiste du g?n?ral'),
  ('andreas leknessund-nor', 'Andreas Leknessund', 24, 'Sp?cialiste du g?n?ral'),
  ('andrew august-usa', 'Andrew August', 39, 'Sp?cialiste du g?n?ral'),
  ('anna henderson', 'Anna Henderson', 0, 'Profil ? pr?ciser'),
  ('anna van der breggen-ned', 'Anna van der Breggen', 30, 'Sp?cialiste du g?n?ral'),
  ('anthon charmig-den', 'Anthon Charmig', 61, 'Sp?cialiste du g?n?ral'),
  ('anthony turgis-fra', 'Anthony Turgis', 14, 'Coureur de classiques'),
  ('antoine l hote-fra', 'Antoine L''Hote', 30, 'Sp?cialiste du g?n?ral'),
  ('anton schiffer-ger', 'Anton Schiffer', 12, 'Sp?cialiste du g?n?ral'),
  ('antonia niedermaier', 'Antonia Niedermaier', 0, 'Profil ? pr?ciser'),
  ('antonia niedermaier-ger', 'Antonia Niedermaier', 50, 'Sp?cialiste du g?n?ral'),
  ('antonio morgado-por', 'António Morgado', 20, 'Coureur de classiques'),
  ('antonio tiberi-ita', 'Antonio Tiberi', 55, 'Sp?cialiste du g?n?ral'),
  ('arnaud de lie-bel', 'Arnaud De Lie', 31, 'Sp?cialiste du g?n?ral'),
  ('artem fofonov-fra', 'Artem Fofonov', 2, 'Sp?cialiste du g?n?ral'),
  ('artem nych', 'Artem Nych', 2, 'Sp?cialiste du g?n?ral'),
  ('artem nych-rus', 'Artem Nych', 24, 'Sp?cialiste du g?n?ral'),
  ('artem shmidt-usa', 'Artem Shmidt', 15, 'Coureur de classiques'),
  ('arvid de kleijn-ned', 'Arvid de Kleijn', 7, 'Coureur de classiques'),
  ('ashleigh moolman', 'Ashleigh Moolman', 0, 'Profil ? pr?ciser'),
  ('attila valter-hun', 'Attila Valter', 4, 'Sp?cialiste du g?n?ral'),
  ('aubin sparfel-fra', 'Aubin Sparfel', 10, 'Sp?cialiste du g?n?ral'),
  ('aurelien paret peintre-fra', 'Aurélien Paret-Peintre', 14, 'Sp?cialiste du g?n?ral'),
  ('axel laurance-fra', 'Axel Laurance', 24, 'Sp?cialiste du g?n?ral'),
  ('axel mariault-fra', 'Axel Mariault', 25, 'Sp?cialiste du g?n?ral'),
  ('axel van der tuuk-ned', 'Axel van der Tuuk', 4, 'Sp?cialiste du g?n?ral'),
  ('axel zingle-fra', 'Axel Zingle', 9, 'Coureur de classiques'),
  ('baptiste vadic-fra', 'Baptiste Vadic', 2, 'Coureur de classiques'),
  ('bart lemmen-ned', 'Bart Lemmen', 20, 'Sp?cialiste du g?n?ral'),
  ('bauke mollema-ned', 'Bauke Mollema', 7, 'Coureur de classiques'),
  ('ben granger-gbr', 'Ben Granger', 2, 'Sp?cialiste du g?n?ral'),
  ('ben healy-ire', 'Ben Healy', 12, 'Coureur de classiques'),
  ('ben healy-irl', 'Ben Healy', 11, 'Sp?cialiste du g?n?ral'),
  ('ben o connor-aus', 'Ben O''Connor', 12, 'Sp?cialiste du g?n?ral'),
  ('ben oliver-nzl', 'Ben Oliver', 30, 'Sp?cialiste du g?n?ral'),
  ('ben tulett-gbr', 'Ben Tulett', 25, 'Coureur de classiques'),
  ('ben turner-gbr', 'Ben Turner', 6, 'Sp?cialiste du g?n?ral'),
  ('benoit cosnefroy-fra', 'Benoît Cosnefroy', 125, 'Sp?cialiste du g?n?ral'),
  ('biniam girmay-eri', 'Biniam Girmay', 31, 'Coureur de classiques'),
  ('bjoern koerdt-gbr', 'Bjoern Koerdt', 2, 'Sp?cialiste du g?n?ral'),
  ('blanka vas-hun', 'Blanka Vas', 7, 'Coureur de classiques'),
  ('brady gilmore-aus', 'Brady Gilmore', 11, 'Coureur de classiques'),
  ('brandon mcnulty-usa', 'Brandon McNulty', 49, 'Sp?cialiste du g?n?ral'),
  ('brent van moer-bel', 'Brent Van Moer', 2, 'Coureur de classiques'),
  ('brian uriarte', 'Brian Uriarte', 18, 'Coureur de classiques'),
  ('bryan coquard-fra', 'Bryan Coquard', 2, 'Sp?cialiste du g?n?ral'),
  ('cameron scott-aus', 'Cameron Scott', 14, 'Sp?cialiste du g?n?ral'),
  ('carlos canal-esp', 'Carlos Canal', 6, 'Sp?cialiste du g?n?ral'),
  ('carlos garcia pierna-esp', 'Carlos García Pierna', 2, 'Sp?cialiste du g?n?ral'),
  ('carlos rodriguez-esp', 'Carlos Rodríguez', 2, 'Coureur de classiques'),
  ('caroline andersson-swe', 'Caroline Andersson', 14, 'Sp?cialiste du g?n?ral'),
  ('carter bettles-aus', 'Carter Bettles', 6, 'Sp?cialiste du g?n?ral'),
  ('casey o gorman', 'Casey O''Gorman', 0, 'Profil ? pr?ciser'),
  ('cecilie uttrup ludwig-den', 'Cecilie Uttrup Ludwig', 6, 'Sp?cialiste du g?n?ral'),
  ('cedrik bakke christophersen-nor', 'Cedrik Bakke Christophersen', 8, 'Sp?cialiste du g?n?ral'),
  ('cedrine kerbaol', 'Cédrine Kerbaol', 0, 'Profil ? pr?ciser'),
  ('cedrine kerbaol-fra', 'Cédrine Kerbaol', 40, 'Sp?cialiste du g?n?ral'),
  ('cees bol-ned', 'Cees Bol', 3, 'Coureur de classiques'),
  ('celia gery', 'Célia Gery', 8, 'Sp?cialiste du g?n?ral'),
  ('celia gery-fra', 'Célia Gery', 2, 'Coureur de classiques'),
  ('cesar perez-esp', 'César Pérez', 2, 'Coureur de classiques'),
  ('charlotte kool-ned', 'Charlotte Kool', 4, 'Coureur de classiques'),
  ('chiara consonni-ita', 'Chiara Consonni', 2, 'Coureur de classiques'),
  ('chris harper-aus', 'Chris Harper', 8, 'Sp?cialiste du g?n?ral'),
  ('christian scaroni-ita', 'Christian Scaroni', 95, 'Sp?cialiste du g?n?ral'),
  ('christophe laporte-fra', 'Christophe Laporte', 39, 'Coureur de classiques'),
  ('cian uijtdebroeks-bel', 'Cian Uijtdebroeks', 20, 'Sp?cialiste du g?n?ral'),
  ('clara copponi-fra', 'Clara Copponi', 18, 'Sp?cialiste du g?n?ral'),
  ('clement alleno-fra', 'Clément Alleno', 8, 'Sp?cialiste du g?n?ral'),
  ('clement berthet-fra', 'Clément Berthet', 13, 'Sp?cialiste du g?n?ral'),
  ('clement braz afonso-fra', 'Clément Braz Afonso', 10, 'Sp?cialiste du g?n?ral'),
  ('clement champoussin-fra', 'Clément Champoussin', 15, 'Sp?cialiste du g?n?ral'),
  ('clement izquierdo-fra', 'Clément Izquierdo', 21, 'Sp?cialiste du g?n?ral'),
  ('clement venturini-fra', 'Clément Venturini', 40, 'Sp?cialiste du g?n?ral'),
  ('corbin strong-nzl', 'Corbin Strong', 33, 'Sp?cialiste du g?n?ral'),
  ('cormac buchanan', 'Cormac Buchanan', 0, 'Profil ? pr?ciser'),
  ('cristian rodriguez-esp', 'Cristián Rodríguez', 36, 'Sp?cialiste du g?n?ral'),
  ('daan hoole-ned', 'Daan Hoole', 6, 'Coureur de classiques'),
  ('damiano caruso-ita', 'Damiano Caruso', 4, 'Sp?cialiste du g?n?ral'),
  ('daniel martinez-col', 'Daniel Martínez', 34, 'Sp?cialiste du g?n?ral'),
  ('danny van poppel-ned', 'Danny van Poppel', 12, 'Coureur de classiques'),
  ('dario giuliano-fra', 'Dario Giuliano', 1, 'Coureur de classiques'),
  ('david almansa', 'David Almansa', 24, 'Coureur de classiques'),
  ('david dekker-ned', 'David Dekker', 4, 'Coureur de classiques'),
  ('david gonzalez', 'David González', 0, 'Profil ? pr?ciser'),
  ('david munoz', 'David Muñoz', 0, 'Profil ? pr?ciser'),
  ('davide donati-ita', 'Davide Donati', 4, 'Coureur de classiques'),
  ('davide piganzoli-ita', 'Davide Piganzoli', 56, 'Sp?cialiste du g?n?ral'),
  ('demi vollering-ned', 'Demi Vollering', 60, 'Sp?cialiste du g?n?ral'),
  ('derek gee west-can', 'Derek Gee-West', 20, 'Sp?cialiste du g?n?ral'),
  ('diego pescador-col', 'Diego Pescador', 6, 'Sp?cialiste du g?n?ral'),
  ('diego ulissi-ita', 'Diego Ulissi', 17, 'Sp?cialiste du g?n?ral'),
  ('diego uriarte-esp', 'Diego Uriarte', 6, 'Sp?cialiste du g?n?ral'),
  ('diogo barbosa-por', 'Diogo Barbosa', 2, 'Sp?cialiste du g?n?ral'),
  ('domenico pozzovivo-ita', 'Domenico Pozzovivo', 20, 'Sp?cialiste du g?n?ral'),
  ('dominika w odarczyk-pol', 'Dominika Włodarczyk', 24, 'Sp?cialiste du g?n?ral'),
  ('dominika wlodarczyk', 'Dominika Wlodarczyk', 6, 'Sp?cialiste du g?n?ral'),
  ('dorian godon-fra', 'Dorian Godon', 37, 'Sp?cialiste du g?n?ral'),
  ('dusan rajovic-srb', 'Dušan Rajović', 15, 'Sp?cialiste du g?n?ral'),
  ('dylan groenewegen-ned', 'Dylan Groenewegen', 22, 'Coureur de classiques'),
  ('dylan hopkins-aus', 'Dylan Hopkins', 12, 'Sp?cialiste du g?n?ral'),
  ('dylan teuns-bel', 'Dylan Teuns', 10, 'Sp?cialiste du g?n?ral'),
  ('eddie o shea', 'Eddie O''Shea', 0, 'Profil ? pr?ciser'),
  ('edgar cadena-mex', 'Edgar Cadena', 2, 'Sp?cialiste du g?n?ral'),
  ('eduard prades-esp', 'Eduard Prades', 6, 'Coureur de classiques'),
  ('eduard prades-spa', 'Eduard Prades', 3, 'Coureur de classiques'),
  ('eduardo gutierrez', 'Eduardo Gutiérrez', 0, 'Profil ? pr?ciser'),
  ('eduardo sepulveda-arg', 'Eduardo Sepúlveda', 8, 'Sp?cialiste du g?n?ral'),
  ('egan bernal-col', 'Egan Bernal', 36, 'Sp?cialiste du g?n?ral'),
  ('eike behrens-ger', 'Eike Behrens', 2, 'Sp?cialiste du g?n?ral'),
  ('eivind broholt fougner-nor', 'Eivind Broholt Fougner', 12, 'Sp?cialiste du g?n?ral'),
  ('eleonora ciabocco-ita', 'Eleonora Ciabocco', 10, 'Sp?cialiste du g?n?ral'),
  ('eleonora gasparrini', 'Eleonora Gasparrini', 0, 'Profil ? pr?ciser'),
  ('eleonora gasparrini-ita', 'Eleonora Gasparrini', 18, 'Coureur de classiques'),
  ('elisa balsamo-ita', 'Elisa Balsamo', 6, 'Coureur de classiques'),
  ('elisa longo borghini-ita', 'Elisa Longo Borghini', 66, 'Sp?cialiste du g?n?ral'),
  ('elliot rowe-gbr', 'Elliot Rowe', 3, 'Coureur de classiques'),
  ('emanuel buchmann-ger', 'Emanuel Buchmann', 4, 'Sp?cialiste du g?n?ral'),
  ('emanuel duarte-por', 'Emanuel Duarte', 6, 'Sp?cialiste du g?n?ral'),
  ('embret svestad bardseng-nor', 'Embret Svestad-Bårdseng', 6, 'Sp?cialiste du g?n?ral'),
  ('emiel verstrynge-bel', 'Emiel Verstrynge', 13, 'Coureur de classiques'),
  ('emil herzog-ger', 'Emil Herzog', 7, 'Coureur de classiques'),
  ('emilien jeanniere-fra', 'Emilien Jeannière', 16, 'Coureur de classiques'),
  ('emils liepins-lat', 'Emīls Liepiņš', 1, 'Coureur de classiques'),
  ('enric mas-esp', 'Enric Mas', 54, 'Sp?cialiste du g?n?ral'),
  ('enrico zanoncello-ita', 'Enrico Zanoncello', 4, 'Coureur de classiques'),
  ('eric antonio fagundez-uru', 'Eric Antonio Fagúndez', 14, 'Sp?cialiste du g?n?ral'),
  ('eric fagundez-uru', 'Eric Fagúndez', 14, 'Sp?cialiste du g?n?ral'),
  ('evita muzic', 'Évita Muzic', 0, 'Profil ? pr?ciser'),
  ('evita muzic-fra', 'Évita Muzic', 34, 'Sp?cialiste du g?n?ral'),
  ('ewen costiou-fra', 'Ewen Costiou', 32, 'Sp?cialiste du g?n?ral'),
  ('fabio christen-sui', 'Fabio Christen', 7, 'Coureur de classiques'),
  ('fabrizio crozzolo-arg', 'Fabrizio Crozzolo', 6, 'Sp?cialiste du g?n?ral'),
  ('federico iacomoni-ita', 'Federico Iacomoni', 3, 'Coureur de classiques'),
  ('felix engelhardt-ger', 'Felix Engelhardt', 14, 'Sp?cialiste du g?n?ral'),
  ('felix gall-aut', 'Felix Gall', 94, 'Sp?cialiste du g?n?ral'),
  ('felix gro schartner-aut', 'Felix Großschartner', 3, 'Coureur de classiques'),
  ('femke de vries', 'Femke de Vries', 0, 'Profil ? pr?ciser'),
  ('femke de vries-ned', 'Femke de Vries', 52, 'Sp?cialiste du g?n?ral'),
  ('fergus browning-aus', 'Fergus Browning', 8, 'Sp?cialiste du g?n?ral'),
  ('fernando barcelo-esp', 'Fernando Barceló', 3, 'Coureur de classiques'),
  ('fernando gaviria-col', 'Fernando Gaviria', 1, 'Coureur de classiques'),
  ('fernando tercero-esp', 'Fernando Tercero', 10, 'Sp?cialiste du g?n?ral'),
  ('filippo baroncini-ita', 'Filippo Baroncini', 2, 'Coureur de classiques'),
  ('filippo fiorelli-ita', 'Filippo Fiorelli', 17, 'Sp?cialiste du g?n?ral'),
  ('filippo ganna-ita', 'Filippo Ganna', 27, 'Coureur de classiques'),
  ('filippo turconi-ita', 'Filippo Turconi', 14, 'Sp?cialiste du g?n?ral'),
  ('filippo zana-ita', 'Filippo Zana', 19, 'Sp?cialiste du g?n?ral'),
  ('finlay pickering-gbr', 'Finlay Pickering', 4, 'Coureur de classiques'),
  ('finn fisher black-nzl', 'Finn Fisher-Black', 24, 'Sp?cialiste du g?n?ral'),
  ('florian dauphin-fra', 'Florian Dauphin', 7, 'Coureur de classiques'),
  ('florian lipowitz-ger', 'Florian Lipowitz', 102, 'Sp?cialiste du g?n?ral'),
  ('florian senechal-fra', 'Florian Sénéchal', 5, 'Coureur de classiques'),
  ('florian stork-ger', 'Florian Stork', 2, 'Coureur de classiques'),
  ('florian vermeersch-bel', 'Florian Vermeersch', 22, 'Coureur de classiques'),
  ('francesca barale', 'Francesca Barale', 0, 'Profil ? pr?ciser'),
  ('francesco busatto-ita', 'Francesco Busatto', 2, 'Coureur de classiques'),
  ('francisco joel penuela-ven', 'Francisco Joel Peñuela', 5, 'Coureur de classiques'),
  ('franziska koch', 'Franziska Koch', 2, 'Sp?cialiste du g?n?ral'),
  ('fred wright-gbr', 'Fred Wright', 7, 'Coureur de classiques'),
  ('fredrik dversnes-nor', 'Fredrik Dversnes', 5, 'Coureur de classiques'),
  ('frits biesterbos-ned', 'Frits Biesterbos', 24, 'Coureur de classiques'),
  ('gal glivar-slo', 'Gal Glivar', 3, 'Coureur de classiques'),
  ('gari ugarte-esp', 'Gari Ugarte', 6, 'Sp?cialiste du g?n?ral'),
  ('georg steinhauser-ger', 'Georg Steinhauser', 18, 'Sp?cialiste du g?n?ral'),
  ('georg zimmermann-ger', 'Georg Zimmermann', 15, 'Coureur de classiques'),
  ('george bennett-nzl', 'George Bennett', 6, 'Sp?cialiste du g?n?ral'),
  ('gerben thijssen-bel', 'Gerben Thijssen', 1, 'Coureur de classiques'),
  ('gianni vermeersch-bel', 'Gianni Vermeersch', 9, 'Coureur de classiques'),
  ('ginia lara caluori fr', 'Ginia-Lara Caluori [ fr ]', 0, 'Profil ? pr?ciser'),
  ('giovanni aleotti-ita', 'Giovanni Aleotti', 8, 'Sp?cialiste du g?n?ral'),
  ('giulio ciccone-ita', 'Giulio Ciccone', 42, 'Sp?cialiste du g?n?ral'),
  ('giulio pellizzari-ita', 'Giulio Pellizzari', 128, 'Sp?cialiste du g?n?ral'),
  ('gleb syritsa', 'Gleb Syritsa', 18, 'Sp?cialiste du g?n?ral'),
  ('gorka sorarrain-esp', 'Gorka Sorarrain', 14, 'Sp?cialiste du g?n?ral'),
  ('gregor muhlberger-aut', 'Gregor Mühlberger', 15, 'Coureur de classiques'),
  ('guido pini', 'Guido Pini', 0, 'Profil ? pr?ciser'),
  ('guillaume martin-fra', 'Guillaume Martin', 2, 'Sp?cialiste du g?n?ral'),
  ('guillermo thomas silva-uru', 'Guillermo Thomas Silva', 60, 'Sp?cialiste du g?n?ral'),
  ('haimar etxeberria-esp', 'Haimar Etxeberria', 1, 'Coureur de classiques'),
  ('hakim danish', 'Hakim Danish', 4, 'Coureur de classiques'),
  ('harold tejada-col', 'Harold Tejada', 18, 'Sp?cialiste du g?n?ral'),
  ('harry sweeny-aus', 'Harry Sweeny', 36, 'Sp?cialiste du g?n?ral'),
  ('hector alvarez-esp', 'Héctor Álvarez', 13, 'Coureur de classiques'),
  ('henok mulubrhan-eri', 'Henok Mulubrhan', 21, 'Sp?cialiste du g?n?ral'),
  ('henok mulueberhan-eri', 'Henok Mulueberhan', 24, 'Sp?cialiste du g?n?ral'),
  ('henri uhlig-ger', 'Henri Uhlig', 6, 'Coureur de classiques'),
  ('henri vandenabeele-bel', 'Henri Vandenabeele', 2, 'Sp?cialiste du g?n?ral'),
  ('henrietta christie', 'Henrietta Christie', 0, 'Profil ? pr?ciser'),
  ('henrietta colborne-gbr', 'Henrietta Colborne', 4, 'Sp?cialiste du g?n?ral'),
  ('henrique bravo-bra', 'Henrique Bravo', 14, 'Sp?cialiste du g?n?ral'),
  ('hugo hofstetter-fra', 'Hugo Hofstetter', 20, 'Coureur de classiques'),
  ('huub artz-ned', 'Huub Artz', 2, 'Coureur de classiques'),
  ('huw buck jones-gbr', 'Huw Buck Jones', 6, 'Sp?cialiste du g?n?ral'),
  ('igor arrieta-esp', 'Igor Arrieta', 44, 'Sp?cialiste du g?n?ral'),
  ('ilan van wilder-bel', 'Ilan Van Wilder', 12, 'Sp?cialiste du g?n?ral'),
  ('ion izagirre-esp', 'Ion Izagirre', 67, 'Sp?cialiste du g?n?ral'),
  ('isaac del toro-mex', 'Isaac del Toro', 165, 'Sp?cialiste du g?n?ral'),
  ('isabella holmgren-can', 'Isabella Holmgren', 14, 'Sp?cialiste du g?n?ral'),
  ('ivan cobo-esp', 'Iván Cobo', 12, 'Sp?cialiste du g?n?ral'),
  ('ivan romeo-esp', 'Iván Romeo', 60, 'Sp?cialiste du g?n?ral'),
  ('ivo oliveira-por', 'Ivo Oliveira', 30, 'Sp?cialiste du g?n?ral'),
  ('j rgen nordhagen-nor', 'Jørgen Nordhagen', 44, 'Sp?cialiste du g?n?ral'),
  ('jai hindley-aus', 'Jai Hindley', 23, 'Sp?cialiste du g?n?ral'),
  ('jakob omrzel-slo', 'Jakob Omrzel', 42, 'Sp?cialiste du g?n?ral'),
  ('jakob soderqvist-swe', 'Jakob Söderqvist', 30, 'Sp?cialiste du g?n?ral'),
  ('jamie meehan-irl', 'Jamie Meehan', 18, 'Sp?cialiste du g?n?ral'),
  ('jan castellon-esp', 'Jan Castellon', 46, 'Sp?cialiste du g?n?ral'),
  ('jan christen-sui', 'Jan Christen', 71, 'Sp?cialiste du g?n?ral'),
  ('jan hirt-cze', 'Jan Hirt', 4, 'Sp?cialiste du g?n?ral'),
  ('jardi christiaan van der lee-ned', 'Jardi Christiaan van der Lee', 4, 'Sp?cialiste du g?n?ral'),
  ('jarmila machacova-cze', 'Jarmila Machacova', 6, 'Sp?cialiste du g?n?ral'),
  ('jarno widar-bel', 'Jarno Widar', 37, 'Sp?cialiste du g?n?ral'),
  ('jason tesson-fra', 'Jason Tesson', 8, 'Coureur de classiques'),
  ('jasper philipsen-bel', 'Jasper Philipsen', 99, 'Sp?cialiste du g?n?ral'),
  ('jasper stuyven-bel', 'Jasper Stuyven', 29, 'Coureur de classiques'),
  ('javier romo-esp', 'Javier Romo', 8, 'Sp?cialiste du g?n?ral'),
  ('jay vine-aus', 'Jay Vine', 60, 'Sp?cialiste du g?n?ral'),
  ('jefferson alexander cepeda-col', 'Jefferson Alexander Cepeda', 8, 'Sp?cialiste du g?n?ral'),
  ('jefferson alexander cepeda-ecu', 'Jefferson Alexander Cepeda', 5, 'Coureur de classiques'),
  ('jefferson alveiro cepeda-ecu', 'Jefferson Alveiro Cepeda', 11, 'Sp?cialiste du g?n?ral'),
  ('jenno berckmoes-bel', 'Jenno Berckmoes', 45, 'Sp?cialiste du g?n?ral'),
  ('jenthe biermans-bel', 'Jenthe Biermans', 11, 'Coureur de classiques'),
  ('jesus herrada-esp', 'Jesús Herrada', 4, 'Sp?cialiste du g?n?ral'),
  ('jesus rios', 'Jesús Ríos', 0, 'Profil ? pr?ciser'),
  ('jhonatan narvaez-col', 'Jhonatan Narváez', 2, 'Coureur de classiques'),
  ('jhonatan narvaez-ecu', 'Jhonatan Narváez', 8, 'Sp?cialiste du g?n?ral'),
  ('joao almeida-por', 'João Almeida', 42, 'Sp?cialiste du g?n?ral'),
  ('joel esteban', 'Joel Esteban', 0, 'Profil ? pr?ciser'),
  ('joel kelso', 'Joel Kelso', 0, 'Profil ? pr?ciser'),
  ('joel nicolau-esp', 'Joel Nicolau', 8, 'Sp?cialiste du g?n?ral'),
  ('johannes kulset-nor', 'Johannes Kulset', 2, 'Sp?cialiste du g?n?ral'),
  ('jokin murguialday-esp', 'Jokin Murguialday', 8, 'Sp?cialiste du g?n?ral'),
  ('jon barrenetxea-esp', 'Jon Barrenetxea', 3, 'Sp?cialiste du g?n?ral'),
  ('jonas abrahamsen-nor', 'Jonas Abrahamsen', 14, 'Coureur de classiques'),
  ('jonas vingegaard-den', 'Jonas Vingegaard', 90, 'Sp?cialiste du g?n?ral'),
  ('jonathan klever caicedo-ecu', 'Jonathan Klever Caicedo', 30, 'Sp?cialiste du g?n?ral'),
  ('jordan jegat-fra', 'Jordan Jegat', 21, 'Sp?cialiste du g?n?ral'),
  ('jordi lopez-esp', 'Jordi López', 22, 'Sp?cialiste du g?n?ral'),
  ('jordi meeus-bel', 'Jordi Meeus', 68, 'Coureur de classiques'),
  ('jorge gutierrez-esp', 'Jorge Gutiérrez', 10, 'Sp?cialiste du g?n?ral'),
  ('joris delbove-fra', 'Joris Delbove', 8, 'Sp?cialiste du g?n?ral'),
  ('jose felix parra-esp', 'José Félix Parra', 14, 'Sp?cialiste du g?n?ral'),
  ('jose fernandes-por', 'José Fernandes', 14, 'Sp?cialiste du g?n?ral'),
  ('jose manuel diaz-esp', 'José Manuel Díaz', 14, 'Sp?cialiste du g?n?ral'),
  ('jose said cisneros-mex', 'José Said Cisneros', 2, 'Sp?cialiste du g?n?ral'),
  ('joseph pidcock-gbr', 'Joseph Pidcock', 3, 'Coureur de classiques'),
  ('josh burnett-nzl', 'Josh Burnett', 38, 'Sp?cialiste du g?n?ral'),
  ('joshua giddings-gbr', 'Joshua Giddings', 24, 'Sp?cialiste du g?n?ral'),
  ('josie nelson-gbr', 'Josie Nelson', 4, 'Sp?cialiste du g?n?ral'),
  ('josie talbot-aus', 'Josie Talbot', 2, 'Sp?cialiste du g?n?ral'),
  ('juan ayuso-esp', 'Juan Ayuso', 64, 'Sp?cialiste du g?n?ral'),
  ('juan ayuso-spa', 'Juan Ayuso', 10, 'Sp?cialiste du g?n?ral'),
  ('juan sebastian molano-col', 'Juan Sebastián Molano', 9, 'Coureur de classiques'),
  ('julien bernard-fra', 'Julien Bernard', 5, 'Coureur de classiques'),
  ('juliette berthet', 'Juliette Berthet', 12, 'Sp?cialiste du g?n?ral'),
  ('juliette berthet-fra', 'Juliette Berthet', 14, 'Sp?cialiste du g?n?ral'),
  ('julius johansen-den', 'Julius Johansen', 12, 'Coureur de classiques'),
  ('junior lecerf-bel', 'Junior Lecerf', 16, 'Sp?cialiste du g?n?ral'),
  ('justine ghekiere-bel', 'Justine Ghekiere', 4, 'Sp?cialiste du g?n?ral'),
  ('karlijn swinkels', 'Karlijn Swinkels', 0, 'Profil ? pr?ciser'),
  ('karlijn swinkels-ned', 'Karlijn Swinkels', 25, 'Sp?cialiste du g?n?ral'),
  ('katarzyna niewiadoma phinney-pol', 'Katarzyna Niewiadoma-Phinney', 42, 'Sp?cialiste du g?n?ral'),
  ('katarzyna niewiadoma-pol', 'Katarzyna Niewiadoma', 12, 'Sp?cialiste du g?n?ral'),
  ('katharina sadnik', 'Katharina Sadnik', 0, 'Profil ? pr?ciser'),
  ('kathrin schweinberger-aut', 'Kathrin Schweinberger', 14, 'Sp?cialiste du g?n?ral'),
  ('kevin vauquelin-fra', 'Kévin Vauquelin', 58, 'Sp?cialiste du g?n?ral'),
  ('kevin vermaerke-usa', 'Kevin Vermaerke', 12, 'Coureur de classiques'),
  ('kiattisak singhapong', 'Kiattisak Singhapong', 0, 'Profil ? pr?ciser'),
  ('killian theot-fra', 'Killian Théot', 10, 'Sp?cialiste du g?n?ral'),
  ('kim heiduk-ger', 'Kim Heiduk', 14, 'Sp?cialiste du g?n?ral'),
  ('kim le court pienaar-mri', 'Kim Le Court-Pienaar', 44, 'Sp?cialiste du g?n?ral'),
  ('kimberley le court', 'Kimberley Le Court', 0, 'Profil ? pr?ciser'),
  ('kimberley le court pienaar-mri', 'Kimberley Le Court-Pienaar', 4, 'Sp?cialiste du g?n?ral'),
  ('kimberley le court-mri', 'Kimberley Le Court', 14, 'Sp?cialiste du g?n?ral'),
  ('kristen faulkner', 'Kristen Faulkner', 0, 'Profil ? pr?ciser'),
  ('lander loockx-bel', 'Lander Loockx', 8, 'Sp?cialiste du g?n?ral'),
  ('lara gillespie-irl', 'Lara Gillespie', 24, 'Sp?cialiste du g?n?ral'),
  ('lauren dickson', 'Lauren Dickson', 0, 'Profil ? pr?ciser'),
  ('lauren dickson-gbr', 'Lauren Dickson', 18, 'Sp?cialiste du g?n?ral'),
  ('lauren stephens', 'Lauren Stephens', 0, 'Profil ? pr?ciser'),
  ('laurence pithie-nzl', 'Laurence Pithie', 34, 'Sp?cialiste du g?n?ral'),
  ('laurenz rex-bel', 'Laurenz Rex', 17, 'Coureur de classiques'),
  ('leandre lozouet-fra', 'Léandre Lozouet', 2, 'Sp?cialiste du g?n?ral'),
  ('lennart jasch-ger', 'Lennart Jasch', 42, 'Sp?cialiste du g?n?ral'),
  ('lennert teugels-bel', 'Lennert Teugels', 4, 'Sp?cialiste du g?n?ral'),
  ('lennert van eetvelt-bel', 'Lennert Van Eetvelt', 38, 'Sp?cialiste du g?n?ral'),
  ('lenny martinez-fra', 'Lenny Martinez', 99, 'Sp?cialiste du g?n?ral'),
  ('leo bisiaux-fra', 'Léo Bisiaux', 8, 'Sp?cialiste du g?n?ral'),
  ('leo rammerstorfer', 'Leo Rammerstorfer', 0, 'Profil ? pr?ciser'),
  ('leonardo abruzzo', 'Leonardo Abruzzo', 0, 'Profil ? pr?ciser'),
  ('letizia borghesi-ita', 'Letizia Borghesi', 6, 'Coureur de classiques'),
  ('lewis askey-gbr', 'Lewis Askey', 27, 'Coureur de classiques'),
  ('liane lippert', 'Liane Lippert', 0, 'Profil ? pr?ciser'),
  ('liane lippert-ger', 'Liane Lippert', 18, 'Sp?cialiste du g?n?ral'),
  ('lieke nooijen', 'Lieke Nooijen', 0, 'Profil ? pr?ciser'),
  ('lionel taminiaux-bel', 'Lionel Taminiaux', 6, 'Coureur de classiques'),
  ('lore de schepper-bel', 'Lore De Schepper', 2, 'Sp?cialiste du g?n?ral'),
  ('lorena wiebes-ned', 'Lorena Wiebes', 64, 'Sp?cialiste du g?n?ral'),
  ('lorenzo fortunato-ita', 'Lorenzo Fortunato', 13, 'Sp?cialiste du g?n?ral'),
  ('lorenzo quartucci-ita', 'Lorenzo Quartucci', 18, 'Sp?cialiste du g?n?ral'),
  ('lotte kopecky', 'Lotte Kopecky', 0, 'Profil ? pr?ciser'),
  ('lotte kopecky-bel', 'Lotte Kopecky', 34, 'Coureur de classiques'),
  ('louis barre-fra', 'Louis Barré', 64, 'Sp?cialiste du g?n?ral'),
  ('louis rouland-fra', 'Louis Rouland', 2, 'Sp?cialiste du g?n?ral'),
  ('luca covili-ita', 'Luca Covili', 22, 'Sp?cialiste du g?n?ral'),
  ('luca mozzato-ita', 'Luca Mozzato', 20, 'Coureur de classiques'),
  ('luca van boven-bel', 'Luca Van Boven', 4, 'Coureur de classiques'),
  ('lucas de rossi-fra', 'Lucas De Rossi', 6, 'Sp?cialiste du g?n?ral'),
  ('ludovico crescioli-ita', 'Ludovico Crescioli', 19, 'Sp?cialiste du g?n?ral'),
  ('lukas kubis-svk', 'Lukáš Kubiš', 25, 'Sp?cialiste du g?n?ral'),
  ('lukas nerurkar-gbr', 'Lukas Nerurkar', 10, 'Coureur de classiques'),
  ('luke lamperti-usa', 'Luke Lamperti', 3, 'Coureur de classiques'),
  ('luke mudgway-nzl', 'Luke Mudgway', 26, 'Sp?cialiste du g?n?ral'),
  ('luke plapp-aus', 'Luke Plapp', 57, 'Sp?cialiste du g?n?ral'),
  ('luke tuckwell-aus', 'Luke Tuckwell', 34, 'Sp?cialiste du g?n?ral'),
  ('mads pedersen-den', 'Mads Pedersen', 21, 'Sp?cialiste du g?n?ral'),
  ('maeva squiban', 'Maeva Squiban', 4, 'Sp?cialiste du g?n?ral'),
  ('maggie coles lyster-can', 'Maggie Coles-Lyster', 12, 'Sp?cialiste du g?n?ral'),
  ('magnus sheffield-usa', 'Magnus Sheffield', 14, 'Sp?cialiste du g?n?ral'),
  ('manuel penalver-esp', 'Manuel Peñalver', 2, 'Coureur de classiques'),
  ('marc hirschi-sui', 'Marc Hirschi', 28, 'Sp?cialiste du g?n?ral'),
  ('marc soler-esp', 'Marc Soler', 25, 'Sp?cialiste du g?n?ral'),
  ('marcel camprubi-esp', 'Marcel Camprubí', 10, 'Coureur de classiques'),
  ('marcin budzinski-pol', 'Marcin Budziński', 5, 'Coureur de classiques'),
  ('marco brenner-ger', 'Marco Brenner', 74, 'Sp?cialiste du g?n?ral'),
  ('marco frigo-ita', 'Marco Frigo', 1, 'Coureur de classiques'),
  ('marco morelli', 'Marco Morelli', 10, 'Coureur de classiques'),
  ('marcos uriarte', 'Marcos Uriarte', 0, 'Profil ? pr?ciser'),
  ('margot vanpachtenbeke', 'Margot Vanpachtenbeke', 0, 'Profil ? pr?ciser'),
  ('margot vanpachtenbeke-bel', 'Margot Vanpachtenbeke', 8, 'Sp?cialiste du g?n?ral'),
  ('marianne vos-ned', 'Marianne Vos', 5, 'Coureur de classiques'),
  ('marijn van den berg-ned', 'Marijn van den Berg', 2, 'Coureur de classiques'),
  ('marius mayrhofer-ger', 'Marius Mayrhofer', 3, 'Coureur de classiques'),
  ('markel beloki-esp', 'Markel Beloki', 38, 'Sp?cialiste du g?n?ral'),
  ('markus hoelgaard-nor', 'Markus Hoelgaard', 8, 'Coureur de classiques'),
  ('markus pajur-est', 'Markus Pajur', 12, 'Sp?cialiste du g?n?ral'),
  ('marlen reusser', 'Marlen Reusser', 14, 'Sp?cialiste du g?n?ral'),
  ('marlen reusser-sui', 'Marlen Reusser', 30, 'Sp?cialiste du g?n?ral'),
  ('marte berg edseth', 'Marte Berg Edseth', 0, 'Profil ? pr?ciser'),
  ('martin marcellusi-ita', 'Martin Marcellusi', 12, 'Sp?cialiste du g?n?ral'),
  ('martin tj tta-nor', 'Martin Tjøtta', 16, 'Sp?cialiste du g?n?ral'),
  ('matej mohoric-slo', 'Matej Mohorič', 3, 'Coureur de classiques'),
  ('matevz govekar-slo', 'Matevž Govekar', 7, 'Coureur de classiques'),
  ('matevz govekar-svn', 'Matevž Govekar', 4, 'Coureur de classiques'),
  ('mathias bregnh j-den', 'Mathias Bregnhøj', 16, 'Sp?cialiste du g?n?ral'),
  ('mathias vacek-cze', 'Mathias Vacek', 30, 'Sp?cialiste du g?n?ral'),
  ('mathieu burgaudeau-fra', 'Mathieu Burgaudeau', 3, 'Coureur de classiques'),
  ('mathieu kockelmann-lux', 'Mathieu Kockelmann', 8, 'Sp?cialiste du g?n?ral'),
  ('mathieu van der poel-ned', 'Mathieu van der Poel', 37, 'Coureur de classiques'),
  ('mathis le berre-fra', 'Mathis Le Berre', 4, 'Sp?cialiste du g?n?ral'),
  ('mathys rondel-fra', 'Mathys Rondel', 58, 'Sp?cialiste du g?n?ral'),
  ('matteo bertelle', 'Matteo Bertelle', 2, 'Coureur de classiques'),
  ('matteo fabbro-ita', 'Matteo Fabbro', 14, 'Sp?cialiste du g?n?ral'),
  ('matteo jorgenson-usa', 'Matteo Jorgenson', 66, 'Sp?cialiste du g?n?ral'),
  ('matteo malucelli-ita', 'Matteo Malucelli', 30, 'Sp?cialiste du g?n?ral'),
  ('matteo moschetti-ita', 'Matteo Moschetti', 18, 'Coureur de classiques')
on conflict (rider_id) do update set rider_name = excluded.rider_name, score = excluded.score, profile = excluded.profile;

insert into public.rider_scores (rider_id, rider_name, score, profile) values
  ('matteo regnanti-ita', 'Matteo Regnanti', 4, 'Sp?cialiste du g?n?ral'),
  ('matteo sobrero-ita', 'Matteo Sobrero', 14, 'Sp?cialiste du g?n?ral'),
  ('matteo trentin-ita', 'Matteo Trentin', 26, 'Sp?cialiste du g?n?ral'),
  ('matteo vanhuffel-bel', 'Matteo Vanhuffel', 4, 'Sp?cialiste du g?n?ral'),
  ('matteo vercher-fra', 'Mattéo Vercher', 27, 'Sp?cialiste du g?n?ral'),
  ('matthew brennan-gbr', 'Matthew Brennan', 27, 'Coureur de classiques'),
  ('matthew fox-aus', 'Matthew Fox', 24, 'Sp?cialiste du g?n?ral'),
  ('matthew riccitello-usa', 'Matthew Riccitello', 22, 'Sp?cialiste du g?n?ral'),
  ('mattias skjelmose-den', 'Mattias Skjelmose', 62, 'Sp?cialiste du g?n?ral'),
  ('matyas kopecky-cze', 'Matyáš Kopecký', 2, 'Coureur de classiques'),
  ('matys grisel-fra', 'Matys Grisel', 44, 'Sp?cialiste du g?n?ral'),
  ('maud oudeman-ned', 'Maud Oudeman', 2, 'Sp?cialiste du g?n?ral'),
  ('mauri vansevenant-bel', 'Mauri Vansevenant', 13, 'Sp?cialiste du g?n?ral'),
  ('mauro schmid-sui', 'Mauro Schmid', 131, 'Sp?cialiste du g?n?ral'),
  ('mavi garcia', 'Mavi García', 0, 'Profil ? pr?ciser'),
  ('max bock-ger', 'Max Bock', 10, 'Sp?cialiste du g?n?ral'),
  ('max kanter-ger', 'Max Kanter', 18, 'Coureur de classiques'),
  ('max schachmann-ger', 'Max Schachmann', 4, 'Sp?cialiste du g?n?ral'),
  ('max walscheid-ger', 'Max Walscheid', 10, 'Coureur de classiques'),
  ('maxim van gils-bel', 'Maxim Van Gils', 2, 'Sp?cialiste du g?n?ral'),
  ('maxime decomble-fra', 'Maxime Decomble', 18, 'Sp?cialiste du g?n?ral'),
  ('maximo quiles', 'Máximo Quiles', 30, 'Coureur de classiques'),
  ('michael gogl-aut', 'Michael Gogl', 5, 'Coureur de classiques'),
  ('michael matthews-aus', 'Michael Matthews', 3, 'Coureur de classiques'),
  ('michael storer-aus', 'Michael Storer', 32, 'Sp?cialiste du g?n?ral'),
  ('mick van dijke-ned', 'Mick van Dijke', 5, 'Coureur de classiques'),
  ('mie bj rndal ottestad-nor', 'Mie Bjørndal Ottestad', 9, 'Coureur de classiques'),
  ('mike teunissen-ned', 'Mike Teunissen', 33, 'Sp?cialiste du g?n?ral'),
  ('mikkel honore-den', 'Mikkel Honoré', 9, 'Coureur de classiques'),
  ('milan fretin-bel', 'Milan Fretin', 33, 'Coureur de classiques'),
  ('milan menten-bel', 'Milan Menten', 6, 'Coureur de classiques'),
  ('mireia benito', 'Mireia Benito', 0, 'Profil ? pr?ciser'),
  ('mireia benito-spa', 'Mireia Benito', 14, 'Sp?cialiste du g?n?ral'),
  ('mischa bredewold-ned', 'Mischa Bredewold', 50, 'Sp?cialiste du g?n?ral'),
  ('monica trinca colonel', 'Monica Trinca Colonel', 0, 'Profil ? pr?ciser'),
  ('monica trinca colonel-ita', 'Monica Trinca Colonel', 24, 'Sp?cialiste du g?n?ral'),
  ('nadia gontova', 'Nadia Gontova', 0, 'Profil ? pr?ciser'),
  ('nadia gontova-can', 'Nadia Gontova', 4, 'Sp?cialiste du g?n?ral'),
  ('nairo quintana-col', 'Nairo Quintana', 8, 'Sp?cialiste du g?n?ral'),
  ('natnael tesfatsion-eri', 'Natnael Tesfatsion', 36, 'Sp?cialiste du g?n?ral'),
  ('niamh fisher black-nzl', 'Niamh Fisher-Black', 22, 'Sp?cialiste du g?n?ral'),
  ('nicola carraro', 'Nicola Carraro', 0, 'Profil ? pr?ciser'),
  ('nicola conci-ita', 'Nicola Conci', 24, 'Sp?cialiste du g?n?ral'),
  ('nicolas breuillard-fra', 'Nicolas Breuillard', 12, 'Sp?cialiste du g?n?ral'),
  ('nicolas vinokurov-kaz', 'Nicolas Vinokurov', 18, 'Sp?cialiste du g?n?ral'),
  ('nicolo buratti-ita', 'Nicolo Buratti', 4, 'Coureur de classiques'),
  ('nicolo garibbo-ita', 'Nicolò Garibbo', 10, 'Sp?cialiste du g?n?ral'),
  ('niklas larsen-den', 'Niklas Larsen', 12, 'Sp?cialiste du g?n?ral'),
  ('nil gimeno-esp', 'Nil Gimeno', 14, 'Sp?cialiste du g?n?ral'),
  ('nils politt-ger', 'Nils Politt', 2, 'Coureur de classiques'),
  ('nina berton', 'Nina Berton', 0, 'Profil ? pr?ciser'),
  ('noa isidore-fra', 'Noa Isidore', 45, 'Sp?cialiste du g?n?ral'),
  ('noah hobbs-gbr', 'Noah Hobbs', 4, 'Coureur de classiques'),
  ('noemi ruegg', 'Noemi Ruegg', 0, 'Profil ? pr?ciser'),
  ('noemi ruegg-sui', 'Noemi Rüegg', 27, 'Coureur de classiques'),
  ('olav kooij-ned', 'Olav Kooij', 33, 'Sp?cialiste du g?n?ral'),
  ('orluis aular-ven', 'Orluis Aular', 14, 'Coureur de classiques'),
  ('oscar onley-gbr', 'Oscar Onley', 57, 'Sp?cialiste du g?n?ral'),
  ('pascal ackermann-ger', 'Pascal Ackermann', 15, 'Coureur de classiques'),
  ('pau marti-esp', 'Pau Martí', 10, 'Coureur de classiques'),
  ('pau miquel-esp', 'Pau Miquel', 12, 'Coureur de classiques'),
  ('paul double-gbr', 'Paul Double', 15, 'Sp?cialiste du g?n?ral'),
  ('paul hennequin-fra', 'Paul Hennequin', 10, 'Sp?cialiste du g?n?ral'),
  ('paul lapeira-fra', 'Paul Lapeira', 49, 'Sp?cialiste du g?n?ral'),
  ('paul magnier-fra', 'Paul Magnier', 39, 'Coureur de classiques'),
  ('paul penhoet-fra', 'Paul Penhoët', 11, 'Coureur de classiques'),
  ('paul seixas-fra', 'Paul Seixas', 151, 'Sp?cialiste du g?n?ral'),
  ('paul wright-nzl', 'Paul Wright', 1, 'Coureur de classiques'),
  ('paula blasi-esp', 'Paula Blasi', 12, 'Sp?cialiste du g?n?ral'),
  ('paula patino', 'Paula Patino', 0, 'Profil ? pr?ciser'),
  ('pavel bittner-cze', 'Pavel Bittner', 21, 'Coureur de classiques'),
  ('pavel sivakov-fra', 'Pavel Sivakov', 9, 'Coureur de classiques'),
  ('pedro silva-por', 'Pedro Silva', 18, 'Sp?cialiste du g?n?ral'),
  ('pello bilbao-esp', 'Pello Bilbao', 33, 'Sp?cialiste du g?n?ral'),
  ('pepijn reinderink-ned', 'Pepijn Reinderink', 9, 'Sp?cialiste du g?n?ral'),
  ('per strand hagenes-nor', 'Per Strand Hagenes', 28, 'Coureur de classiques'),
  ('pfeiffer georgi', 'Pfeiffer Georgi', 0, 'Profil ? pr?ciser'),
  ('phil bauhaus-ger', 'Phil Bauhaus', 6, 'Coureur de classiques'),
  ('pierre gautherat-fra', 'Pierre Gautherat', 19, 'Coureur de classiques'),
  ('primoz roglic-slo', 'Primož Roglič', 51, 'Sp?cialiste du g?n?ral'),
  ('puck pieterse', 'Puck Pieterse', 10, 'Sp?cialiste du g?n?ral'),
  ('puck pieterse-ned', 'Puck Pieterse', 14, 'Coureur de classiques'),
  ('quinn simmons-usa', 'Quinn Simmons', 27, 'Coureur de classiques'),
  ('quinten hermans-bel', 'Quinten Hermans', 41, 'Sp?cialiste du g?n?ral'),
  ('rasmus tiller-nor', 'Rasmus Tiller', 11, 'Coureur de classiques'),
  ('remco evenepoel-bel', 'Remco Evenepoel', 123, 'Sp?cialiste du g?n?ral'),
  ('remi arsac-fra', 'Rémi Arsac', 12, 'Sp?cialiste du g?n?ral'),
  ('ricarda bauernfeind-ger', 'Ricarda Bauernfeind', 2, 'Sp?cialiste du g?n?ral'),
  ('richard carapaz-ecu', 'Richard Carapaz', 52, 'Sp?cialiste du g?n?ral'),
  ('rick pluimers-ned', 'Rick Pluimers', 12, 'Coureur de classiques'),
  ('rico salmela', 'Rico Salmela', 0, 'Profil ? pr?ciser'),
  ('riejanne markus', 'Riejanne Markus', 0, 'Profil ? pr?ciser'),
  ('riejanne markus-ned', 'Riejanne Markus', 16, 'Sp?cialiste du g?n?ral'),
  ('riley sheehan-usa', 'Riley Sheehan', 31, 'Sp?cialiste du g?n?ral'),
  ('robert donaldson-gbr', 'Robert Donaldson', 17, 'Sp?cialiste du g?n?ral'),
  ('roger adria-esp', 'Roger Adrià', 11, 'Coureur de classiques'),
  ('romain gregoire-fra', 'Romain Grégoire', 80, 'Sp?cialiste du g?n?ral'),
  ('ruche moodley', 'Ruché Moodley', 0, 'Profil ? pr?ciser'),
  ('rui carvalho-por', 'Rui Carvalho', 4, 'Sp?cialiste du g?n?ral'),
  ('rui oliveira-por', 'Rui Oliveira', 4, 'Coureur de classiques'),
  ('rune herregodts-bel', 'Rune Herregodts', 4, 'Coureur de classiques'),
  ('ryota ogiwara', 'Ryota Ogiwara', 0, 'Profil ? pr?ciser'),
  ('ryusei yamanaka', 'Ryusei Yamanaka', 0, 'Profil ? pr?ciser'),
  ('s ren kragh andersen-den', 'Søren Kragh Andersen', 10, 'Sp?cialiste du g?n?ral'),
  ('s ren w renskjold-nor', 'Søren Wærenskjold', 22, 'Sp?cialiste du g?n?ral'),
  ('sakarias koller l land-nor', 'Sakarias Koller Løland', 1, 'Coureur de classiques'),
  ('sam maisonobe-fra', 'Sam Maisonobe', 4, 'Coureur de classiques'),
  ('sam oomen-ned', 'Sam Oomen', 6, 'Sp?cialiste du g?n?ral'),
  ('sam welsford-aus', 'Sam Welsford', 18, 'Coureur de classiques'),
  ('samuel fernandez-esp', 'Samuel Fernández', 10, 'Sp?cialiste du g?n?ral'),
  ('santiago buitrago-col', 'Santiago Buitrago', 23, 'Sp?cialiste du g?n?ral'),
  ('santiago umba-col', 'Santiago Umba', 8, 'Sp?cialiste du g?n?ral'),
  ('sara casasola', 'Sara Casasola', 0, 'Profil ? pr?ciser'),
  ('sarah gigante', 'Sarah Gigante', 0, 'Profil ? pr?ciser'),
  ('sarah van dam', 'Sarah van Dam', 0, 'Profil ? pr?ciser'),
  ('sarah van dam-can', 'Sarah Van Dam', 8, 'Sp?cialiste du g?n?ral'),
  ('scott ogden', 'Scott Ogden', 0, 'Profil ? pr?ciser'),
  ('sebastian berwick-aus', 'Sebastian Berwick', 38, 'Sp?cialiste du g?n?ral'),
  ('sepp kuss-usa', 'Sepp Kuss', 12, 'Sp?cialiste du g?n?ral'),
  ('sergio higuita-col', 'Sergio Higuita', 28, 'Sp?cialiste du g?n?ral'),
  ('shari bossuyt', 'Shari Bossuyt', 0, 'Profil ? pr?ciser'),
  ('shirin van anrooij-ned', 'Shirin van Anrooij', 11, 'Sp?cialiste du g?n?ral'),
  ('silvia persico', 'Silvia Persico', 0, 'Profil ? pr?ciser'),
  ('simone gualdi-ita', 'Simone Gualdi', 9, 'Coureur de classiques'),
  ('simone velasco-ita', 'Simone Velasco', 1, 'Coureur de classiques'),
  ('stan dewulf-bel', 'Stan Dewulf', 7, 'Coureur de classiques'),
  ('stanis aw anio kowski-pol', 'Stanisław Aniołkowski', 5, 'Coureur de classiques'),
  ('stefan bissegger-sui', 'Stefan Bissegger', 3, 'Coureur de classiques'),
  ('stefan de bod-rsa', 'Stefan De Bod', 14, 'Sp?cialiste du g?n?ral'),
  ('stefano oldani-ita', 'Stefano Oldani', 6, 'Sp?cialiste du g?n?ral'),
  ('steffen de schuyteneer-bel', 'Steffen De Schuyteneer', 12, 'Coureur de classiques'),
  ('steffi haberlin', 'Steffi Haberlin', 0, 'Profil ? pr?ciser'),
  ('steffi haberlin-sui', 'Steffi Häberlin', 16, 'Sp?cialiste du g?n?ral'),
  ('tadej pogacar-slo', 'Tadej Pogačar', 162, 'Sp?cialiste du g?n?ral'),
  ('tang xin-chn', 'Tang Xin', 10, 'Sp?cialiste du g?n?ral'),
  ('thibaud gruel-fra', 'Thibaud Gruel', 40, 'Sp?cialiste du g?n?ral'),
  ('thomas bonnet-fra', 'Thomas Bonnet', 10, 'Sp?cialiste du g?n?ral'),
  ('thomas gachignard-fra', 'Thomas Gachignard', 22, 'Sp?cialiste du g?n?ral'),
  ('thomas gloag-gbr', 'Thomas Gloag', 1, 'Coureur de classiques'),
  ('thomas pesenti-ita', 'Thomas Pesenti', 32, 'Sp?cialiste du g?n?ral'),
  ('thomas pidcock-gbr', 'Thomas Pidcock', 5, 'Coureur de classiques'),
  ('thymen arensman-ned', 'Thymen Arensman', 36, 'Sp?cialiste du g?n?ral'),
  ('tiago antunes-por', 'Tiago Antunes', 10, 'Sp?cialiste du g?n?ral'),
  ('tijmen graat-ned', 'Tijmen Graat', 10, 'Sp?cialiste du g?n?ral'),
  ('tim merlier-bel', 'Tim Merlier', 15, 'Coureur de classiques'),
  ('tim van dijke-ned', 'Tim van Dijke', 12, 'Coureur de classiques'),
  ('tim wellens-bel', 'Tim Wellens', 18, 'Sp?cialiste du g?n?ral'),
  ('tobias foss-nor', 'Tobias Foss', 14, 'Sp?cialiste du g?n?ral'),
  ('tobias halland johannessen-nor', 'Tobias Halland Johannessen', 62, 'Sp?cialiste du g?n?ral'),
  ('tobias lund andresen-den', 'Tobias Lund Andresen', 65, 'Coureur de classiques'),
  ('tobias muller-ger', 'Tobias Müller', 11, 'Coureur de classiques'),
  ('tom crabbe-bel', 'Tom Crabbe', 1, 'Coureur de classiques'),
  ('tom pidcock-gbr', 'Tom Pidcock', 117, 'Sp?cialiste du g?n?ral'),
  ('tommaso dati-ita', 'Tommaso Dati', 12, 'Coureur de classiques'),
  ('toms skujins-lat', 'Toms Skujiņš', 1, 'Coureur de classiques'),
  ('toon aerts-bel', 'Toon Aerts', 3, 'Coureur de classiques'),
  ('tord gudmestad-nor', 'Tord Gudmestad', 14, 'Coureur de classiques'),
  ('txomin juaristi-esp', 'Txomin Juaristi', 8, 'Sp?cialiste du g?n?ral'),
  ('urko berrade-esp', 'Urko Berrade', 10, 'Sp?cialiste du g?n?ral'),
  ('urska zigart-slo', 'Urška Žigart', 6, 'Sp?cialiste du g?n?ral'),
  ('usoa ostolaza-esp', 'Usoa Ostolaza', 8, 'Sp?cialiste du g?n?ral'),
  ('usoa ostolaza-spa', 'Usoa Ostolaza', 18, 'Sp?cialiste du g?n?ral'),
  ('vaclav jezek-cze', 'Václav Ježek', 8, 'Sp?cialiste du g?n?ral'),
  ('valentin ferron-fra', 'Valentin Ferron', 4, 'Coureur de classiques'),
  ('valentin paret peintre-fra', 'Valentin Paret-Peintre', 14, 'Sp?cialiste du g?n?ral'),
  ('valentin perrone', 'Valentín Perrone', 8, 'Coureur de classiques'),
  ('valentina cavallar-aut', 'Valentina Cavallar', 4, 'Sp?cialiste du g?n?ral'),
  ('veda pratama', 'Veda Pratama', 6, 'Coureur de classiques'),
  ('viktor soenens-bel', 'Viktor Soenens', 2, 'Sp?cialiste du g?n?ral'),
  ('vincenzo albanese-ita', 'Vincenzo Albanese', 4, 'Sp?cialiste du g?n?ral'),
  ('vito braet-bel', 'Vito Braet', 2, 'Coureur de classiques'),
  ('walter calzoni-ita', 'Walter Calzoni', 10, 'Sp?cialiste du g?n?ral'),
  ('wout poels-ned', 'Wout Poels', 8, 'Sp?cialiste du g?n?ral'),
  ('wout van aert-bel', 'Wout van Aert', 28, 'Coureur de classiques'),
  ('xabier azparren-esp', 'Xabier Azparren', 4, 'Sp?cialiste du g?n?ral'),
  ('xabier berasategi-esp', 'Xabier Berasategi', 24, 'Sp?cialiste du g?n?ral'),
  ('yannis voisard-sui', 'Yannis Voisard', 12, 'Sp?cialiste du g?n?ral'),
  ('yara kastelijn-ned', 'Yara Kastelijn', 56, 'Sp?cialiste du g?n?ral'),
  ('yuma koishi-jpn', 'Yuma Koishi', 8, 'Sp?cialiste du g?n?ral'),
  ('zak erzen-slo', 'Žak Eržen', 6, 'Coureur de classiques'),
  ('zen mitani', 'Zen Mitani', 0, 'Profil ? pr?ciser'),
  ('zoe backstedt', 'Zoe Bäckstedt', 0, 'Profil ? pr?ciser')
on conflict (rider_id) do update set rider_name = excluded.rider_name, score = excluded.score, profile = excluded.profile;
