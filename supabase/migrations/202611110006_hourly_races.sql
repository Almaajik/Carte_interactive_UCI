create table if not exists public.hourly_races (
  slot_start timestamptz primary key,
  race_slug text not null references public.race_events (slug),
  breakaway_won boolean not null default false,
  race_plan jsonb not null default '{}'::jsonb,
  race_result jsonb,
  settled_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.hourly_races
  add column if not exists breakaway_won boolean not null default false,
  add column if not exists race_plan jsonb not null default '{}'::jsonb;

create table if not exists public.hourly_race_entries (
  slot_start timestamptz not null references public.hourly_races (slot_start) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  display_name text not null,
  rider_ids text[] not null check (cardinality(rider_ids) = 5),
  score integer not null check (score >= 0),
  updated_at timestamptz not null default now(),
  primary key (slot_start, user_id)
);

create table if not exists public.hourly_race_mail (
  id uuid primary key default gen_random_uuid(),
  slot_start timestamptz not null references public.hourly_races (slot_start) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  body text not null,
  drops_reward integer not null default 0 check (drops_reward >= 0),
  boosters_reward integer not null default 0 check (boosters_reward >= 0),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique (slot_start, user_id)
);

create index if not exists hourly_race_entries_standings_idx
  on public.hourly_race_entries (slot_start, score desc, updated_at asc);
create index if not exists hourly_race_mail_inbox_idx
  on public.hourly_race_mail (user_id, created_at desc);

alter table public.hourly_races enable row level security;
alter table public.hourly_race_entries enable row level security;
alter table public.hourly_race_mail enable row level security;

revoke all on public.hourly_races, public.hourly_race_entries, public.hourly_race_mail from anon, authenticated;
grant select (slot_start, race_slug, race_plan, race_result, settled_at, created_at)
  on public.hourly_races to anon, authenticated;
grant select on public.hourly_race_entries, public.hourly_race_mail to authenticated;

drop policy if exists "Hourly race schedule is public" on public.hourly_races;
create policy "Hourly race schedule is public"
  on public.hourly_races for select to anon, authenticated using (true);

drop policy if exists "Hourly race standings are visible to signed-in users" on public.hourly_race_entries;
create policy "Hourly race standings are visible to signed-in users"
  on public.hourly_race_entries for select to authenticated using (true);

drop policy if exists "Users can read their own hourly race mail" on public.hourly_race_mail;
create policy "Users can read their own hourly race mail"
  on public.hourly_race_mail for select to authenticated using ((select auth.uid()) = user_id);

create or replace function public.score_hourly_race_team(p_slot_start timestamptz, p_rider_ids text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_score integer;
  v_count integer;
begin
  select count(*), coalesce(sum(round((
    scores.mountain * events.climb_pct
    + scores.rouleur * events.rolling_pct
    + scores.sprint * events.sprint_pct
  )::numeric / 100)), 0)::integer
    into v_count, v_score
    from public.hourly_races as races
    join public.race_events as events on events.slug = races.race_slug
    cross join unnest(p_rider_ids) as submitted(rider_id)
    join public.rider_scores as scores using (rider_id)
    where races.slot_start = p_slot_start;
  if v_count <> 5 then
    raise exception 'Impossible de calculer le score de cette équipe ou de son parcours.';
  end if;
  return v_score;
end;
$$;

create or replace function public.register_hourly_race_team(p_slot_start timestamptz, p_rider_ids text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_next_slot timestamptz := date_trunc('hour', now() at time zone 'UTC') at time zone 'UTC' + interval '1 hour';
  v_collection jsonb;
  v_owned_count integer;
  v_score_count integer;
  v_score integer;
  v_display_name text;
  v_randomized_riders text[];
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
  if p_slot_start is distinct from v_next_slot then
    raise exception 'Seule la prochaine course accepte les inscriptions.';
  end if;
  if now() < p_slot_start - interval '1 hour'
     or now() >= p_slot_start - interval '5 minutes' then
    raise exception 'Les inscriptions ouvrent une heure avant le départ et ferment cinq minutes avant la course.';
  end if;
  if not exists (
    select 1 from public.hourly_races as races where races.slot_start = p_slot_start
  ) then
    raise exception 'La prochaine course n’est pas encore sélectionnée.';
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
  select count(scores.rider_id) into v_score_count
    from unnest(p_rider_ids) as submitted(rider_id)
    left join public.rider_scores as scores using (rider_id);
  if v_score_count <> 5 then
    raise exception 'Impossible de vérifier le score de cette équipe.';
  end if;
  v_score := public.score_hourly_race_team(p_slot_start, p_rider_ids);
  select coalesce(username, 'Cycliste') into v_display_name
    from public.profiles where user_id = v_user_id;
  v_display_name := coalesce(v_display_name, 'Cycliste');
  insert into public.hourly_race_entries (slot_start, user_id, display_name, rider_ids, score, updated_at)
    values (p_slot_start, v_user_id, v_display_name, p_rider_ids, v_score, now())
    on conflict (slot_start, user_id) do update
      set display_name = excluded.display_name, rider_ids = excluded.rider_ids,
          score = excluded.score, updated_at = excluded.updated_at;
  select array_agg(submitted.rider_id order by random()) into v_randomized_riders
    from unnest(p_rider_ids) as submitted(rider_id);
  update public.hourly_races as races
    set race_plan = races.race_plan || jsonb_build_object(
      'attacker_id', v_randomized_riders[1],
      'dropped_id', v_randomized_riders[2]
    )
    where races.slot_start = p_slot_start and races.race_plan->>'attacker_id' is null;
end;
$$;

create or replace function public.settle_hourly_race(p_slot_start timestamptz)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_race public.hourly_races%rowtype;
  v_race_name text;
  v_escape_probability integer;
  v_unique_riders integer;
  v_breakaway_size integer;
  v_breakaway_ids text[];
  v_finish_ids text[];
  v_breakaway_riders jsonb := '[]'::jsonb;
  v_race_result jsonb;
  v_story jsonb;
  v_breakaway_formed boolean := false;
  v_breakaway_won boolean := false;
  v_breakaway_leader text;
  v_weakest_rider text;
  v_plan jsonb;
  v_entry record;
  v_boosters integer;
  v_award_total integer;
begin
  select races.* into v_race from public.hourly_races as races
    where races.slot_start = p_slot_start for update;
  if not found or v_race.settled_at is not null then
    return;
  end if;
  if now() < p_slot_start + interval '1 hour' then
    return;
  end if;
  select events.name, events.escape_probability
    into v_race_name, v_escape_probability
    from public.race_events as events where events.slug = v_race.race_slug;
  v_plan := v_race.race_plan;

  select count(distinct submitted.rider_id)
    into v_unique_riders
    from public.hourly_race_entries as entries
    cross join lateral unnest(entries.rider_ids) as submitted(rider_id)
    where entries.slot_start = p_slot_start;

  v_breakaway_formed := coalesce((v_plan->>'breakaway_formed')::boolean, false)
    and v_unique_riders >= 3;
  v_breakaway_won := v_breakaway_formed and v_race.breakaway_won;

  if v_breakaway_formed then
    v_breakaway_size := least(v_unique_riders, 3 + floor(random() * 3)::integer);
    select array_agg(sampled.rider_id order by sampled.ability desc, sampled.tie_breaker)
      into v_breakaway_ids
      from (
        select drawn.rider_id,
          (scores.mountain * events.climb_pct
            + scores.rouleur * events.rolling_pct
            + scores.sprint * events.sprint_pct)::numeric / 100 as ability,
          random() as tie_breaker
        from (
          select candidates.rider_id
          from (
            select distinct submitted.rider_id
            from public.hourly_race_entries as entries
            cross join lateral unnest(entries.rider_ids) as submitted(rider_id)
            where entries.slot_start = p_slot_start
              and submitted.rider_id <> coalesce(v_plan->>'dropped_id', '')
          ) as candidates
          order by random()
          limit v_breakaway_size
        ) as drawn
        join public.rider_scores as scores using (rider_id)
        join public.race_events as events on events.slug = v_race.race_slug
      ) as sampled;

    select coalesce(jsonb_agg(
      jsonb_build_object(
        'rider_id', scores.rider_id,
        'rider_name', scores.rider_name,
        'place', places.finish_place
      ) order by places.finish_place
    ), '[]'::jsonb)
      into v_breakaway_riders
      from unnest(v_breakaway_ids) with ordinality as places(rider_id, finish_place)
      join public.rider_scores as scores using (rider_id);
    v_finish_ids := v_breakaway_ids[1:least(3, cardinality(v_breakaway_ids))];
    v_breakaway_leader := v_breakaway_riders->0->>'rider_name';
  end if;

  select scores.rider_name into v_weakest_rider
    from public.hourly_race_entries as entries
    cross join lateral unnest(entries.rider_ids) as submitted(rider_id)
    join public.rider_scores as scores using (rider_id)
    where entries.slot_start = p_slot_start
      and scores.rider_id = coalesce(v_plan->>'dropped_id', '')
      and (v_breakaway_ids is null or scores.rider_id <> all(v_breakaway_ids))
    limit 1;

  if v_weakest_rider is null then
    select scores.rider_name into v_weakest_rider
    from public.hourly_race_entries as entries
    cross join lateral unnest(entries.rider_ids) as submitted(rider_id)
    join public.rider_scores as scores using (rider_id)
    join public.race_events as events on events.slug = v_race.race_slug
    where entries.slot_start = p_slot_start
      and (v_breakaway_ids is null or scores.rider_id <> all(v_breakaway_ids))
    order by (
      scores.mountain * events.climb_pct
      + scores.rouleur * events.rolling_pct
      + scores.sprint * events.sprint_pct
    ) asc, random()
    limit 1;
  end if;

  v_story := jsonb_build_array(
    jsonb_build_object('progress', (v_plan->>'start_progress')::integer, 'title', 'Départ réel',
      'gap_km', 0, 'comment', case (v_plan->>'start_variant')::integer
        when 0 then 'Le peloton s’élance. Les équipes se placent déjà pour contrôler la course.'
        when 1 then 'Départ rapide : chacun cherche à placer ses leaders à l’avant.'
        else 'Le départ est donné; le peloton roule encore groupé.' end),
    jsonb_build_object('progress', (v_plan->>'attack_progress')::integer,
      'title', case when v_breakaway_formed then 'L’échappée se forme' else 'Premières attaques' end,
      'gap_km', (v_plan->>'initial_gap_km')::numeric,
      'comment', case when v_breakaway_formed then
        coalesce(v_breakaway_leader, 'Un groupe de coureurs') || case (v_plan->>'attack_variant')::integer
          when 0 then ' lance une attaque et tente de prendre quelques longueurs.'
          when 1 then ' profite d’un moment de flottement pour sortir du peloton.'
          else ' accélère; plusieurs coureurs sautent dans sa roue.' end
        else case (v_plan->>'attack_variant')::integer
          when 0 then 'Plusieurs attaques partent, mais le peloton contrôle la course.'
          when 1 then 'Un groupe tente de sortir; les équipiers ramènent le peloton.'
          else 'Le rythme s’accélère, sans qu’aucun coureur ne prenne le large.' end
      end),
    jsonb_build_object('progress', (v_plan->>'chase_progress')::integer,
      'title', case (v_plan->>'chase_variant')::integer
        when 0 then 'La chasse s’organise' when 1 then 'Le peloton accélère' else 'L’écart évolue' end,
      'gap_km', (v_plan->>'chased_gap_km')::numeric,
      'comment', case (v_plan->>'chase_variant')::integer
        when 0 then 'Les équipiers se relaient en tête et réduisent l’écart.'
        when 1 then 'Le peloton hausse le rythme; les poursuivants commencent à se regarder.'
        else 'Une équipe organise la chasse tandis que l’échappée creuse son avance.' end),
    jsonb_build_object('progress', (v_plan->>'dropped_progress')::integer,
      'title', case when v_weakest_rider is null then 'Le peloton s’étire'
        else v_weakest_rider || ' est lâché' end,
      'gap_km', (v_plan->>'dropped_gap_km')::numeric,
      'comment', case when v_weakest_rider is null
        then 'La hausse du rythme étire le groupe; plusieurs coureurs peinent à suivre.'
        else v_weakest_rider || ' ne peut suivre l’accélération et perd le contact.' end,
      'dropped_rider', v_weakest_rider),
    jsonb_build_object('progress', (v_plan->>'final_progress')::integer,
      'title', case when (select sprint_finish from public.race_events where slug = v_race.race_slug)
        then 'Les trains se mettent en place' else 'Les favoris accélèrent' end,
      'gap_km', (v_plan->>'final_gap_km')::numeric,
      'comment', case when v_breakaway_won
        then 'L’échappée résiste encore, mais le peloton se rapproche.'
        else case (v_plan->>'final_variant')::integer
          when 0 then 'Le peloton revient à toute allure; le final est relancé.'
          when 1 then 'L’écart s’effondre, les échappés sont presque repris.'
          else 'Les équipes lancent leur dernier effort et bouchent le trou.' end
      end),
    jsonb_build_object('progress', 100, 'title', 'La ligne d’arrivée', 'gap_km',
      case when v_breakaway_won then (v_plan->>'finish_gap_km')::numeric else 0 end,
      'comment', case when v_breakaway_won
        then v_breakaway_leader || ' résiste au retour du peloton et remporte la course !'
        when v_breakaway_formed then 'Le peloton reprend l’échappée avant la ligne. La victoire se joue dans le final.'
        else 'Le peloton reste groupé jusqu’à la ligne et se dispute la victoire.'
      end)
  );

  v_race_result := jsonb_build_object(
    'breakaway_won', v_breakaway_won,
    'escape_probability', v_escape_probability,
    'breakaway_riders', v_breakaway_riders,
    'finish_top3', case when v_breakaway_won then v_breakaway_riders else '[]'::jsonb end,
    'winner', case when v_breakaway_won then v_breakaway_riders->0 else null end,
    'team_bonus', jsonb_build_array(30, 20, 10),
    'story', v_story,
    'settled_at', now()
  );
  update public.hourly_races as races set race_result = v_race_result
    where races.slot_start = p_slot_start;

  update public.hourly_race_entries as entries
    set score = public.score_hourly_race_team(entries.slot_start, entries.rider_ids)
      + coalesce((
        select sum(case places.finish_place when 1 then 30 when 2 then 20 when 3 then 10 else 0 end)::integer
        from unnest(entries.rider_ids) as submitted(rider_id)
        join unnest(v_finish_ids) with ordinality as places(rider_id, finish_place)
          using (rider_id)
      ), 0)
    where entries.slot_start = p_slot_start;

  for v_entry in
    with standings as (
      select user_id, score,
        rank() over (order by score desc)::integer as place,
        count(*) over (partition by score)::integer as tied,
        row_number() over (partition by score order by user_id)::integer as tie_order
      from public.hourly_race_entries as entries where entries.slot_start = p_slot_start
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
    insert into public.hourly_race_mail
      (slot_start, user_id, title, body, drops_reward, boosters_reward)
    values (
      p_slot_start, v_entry.user_id,
      'Résultat · ' || v_race_name,
      case when v_entry.place = 1 then '1re place'
        when v_entry.place = 2 then '2e place'
        when v_entry.place = 3 then '3e place'
        else v_entry.place::text || 'e place' end
        || case when v_entry.tied > 1 then
          ' · Égalité entre ' || v_entry.tied || ' équipes; les boosters des places concernées sont partagés.'
          else '' end
        || case when v_breakaway_won then
          ' · Échappée victorieuse : ' || v_breakaway_leader || '.'
          else ' · Le peloton a repris l’échappée avant l’arrivée.' end,
      20, v_boosters
    )
    on conflict (slot_start, user_id) do nothing;
  end loop;
  update public.hourly_races as races set settled_at = now() where races.slot_start = p_slot_start;
end;
$$;

create or replace function public.settle_due_hourly_races()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot_start timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Connecte-toi pour mettre à jour les résultats.';
  end if;
  for v_slot_start in
    select races.slot_start from public.hourly_races as races
    where races.settled_at is null and races.slot_start + interval '1 hour' <= now()
    order by races.slot_start
  loop
    perform public.settle_hourly_race(v_slot_start);
  end loop;
end;
$$;

drop function if exists public.get_hourly_race();

create function public.get_hourly_race()
returns table (slot_start timestamptz, race_slug text, name text, country text, edition_date date, race_plan jsonb)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_current_slot timestamptz := date_trunc('hour', now() at time zone 'UTC') at time zone 'UTC';
  v_next_slot timestamptz := date_trunc('hour', now() at time zone 'UTC') at time zone 'UTC' + interval '1 hour';
  v_previous_slug text;
  v_race_slug text;
  v_slot_start timestamptz;
  v_escape_probability integer;
  v_breakaway_formed boolean;
  v_breakaway_won boolean;
  v_race_plan jsonb;
begin
  for v_slot_start in
    select races.slot_start from public.hourly_races as races
    where races.settled_at is null and races.slot_start + interval '1 hour' <= now()
    order by races.slot_start
  loop
    perform public.settle_hourly_race(v_slot_start);
  end loop;

  for v_slot_start in select generate_series(v_current_slot, v_next_slot, interval '1 hour')
  loop
    if not exists (
      select 1 from public.hourly_races as races where races.slot_start = v_slot_start
    ) then
      select races.race_slug into v_previous_slug from public.hourly_races as races
        where races.slot_start = v_slot_start - interval '1 hour';
      select events.slug into v_race_slug from public.race_events as events
        where events.slug <> coalesce(v_previous_slug, '')
        order by random() limit 1;
      if v_race_slug is null then
        select events.slug into v_race_slug from public.race_events as events order by random() limit 1;
      end if;
      if v_race_slug is null then
        raise exception 'Le calendrier des courses est vide.';
      end if;
      select events.escape_probability into v_escape_probability
        from public.race_events as events where events.slug = v_race_slug;
      v_breakaway_formed := random() < 0.72;
      v_breakaway_won := v_breakaway_formed
        and random() * 100 < least(100::double precision, v_escape_probability::double precision / 0.72);
      v_race_plan := jsonb_build_object(
        'breakaway_formed', v_breakaway_formed,
        'start_progress', 7 + floor(random() * 5)::integer,
        'attack_progress', 17 + floor(random() * 12)::integer,
        'chase_progress', 37 + floor(random() * 15)::integer,
        'dropped_progress', 57 + floor(random() * 16)::integer,
        'final_progress', 82 + floor(random() * 12)::integer,
        'start_variant', floor(random() * 3)::integer,
        'attack_variant', floor(random() * 3)::integer,
        'chase_variant', floor(random() * 3)::integer,
        'final_variant', floor(random() * 3)::integer,
        'initial_gap_km', case when v_breakaway_formed
          then round((2 + random() * 4)::numeric, 1)
          else round((0.4 + random() * 1.8)::numeric, 1) end,
        'chased_gap_km', case when v_breakaway_won
          then round((0.7 + random() * 1.1)::numeric, 1)
          else round((random() * 0.8)::numeric, 1) end,
        'dropped_gap_km', round((random() * 1.4)::numeric, 1),
        'final_gap_km', case when v_breakaway_won
          then round((0.3 + random() * 1.1)::numeric, 1)
          else round((random() * 0.35)::numeric, 1) end,
        'finish_gap_km', round((0.1 + random() * 0.7)::numeric, 1)
      );
      insert into public.hourly_races (slot_start, race_slug, breakaway_won, race_plan)
        values (v_slot_start, v_race_slug, v_breakaway_won, v_race_plan)
        on conflict on constraint hourly_races_pkey do nothing;
    end if;
  end loop;
  return query
    select races.slot_start, events.slug, events.name, events.country, events.race_date, races.race_plan
    from public.hourly_races as races
    join public.race_events as events on events.slug = races.race_slug
    where races.slot_start in (v_current_slot, v_next_slot)
    order by races.slot_start;
end;
$$;

create or replace function public.claim_hourly_race_reward(p_mail_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_mail public.hourly_race_mail%rowtype;
begin
  if v_user_id is null then
    raise exception 'Connecte-toi pour réclamer une récompense.';
  end if;
  select * into v_mail from public.hourly_race_mail
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
  update public.hourly_race_mail set claimed_at = now() where id = p_mail_id;
end;
$$;

revoke all on function public.score_hourly_race_team(timestamptz, text[]) from public, anon, authenticated;
revoke all on function public.register_hourly_race_team(timestamptz, text[]) from public, anon, authenticated;
revoke all on function public.settle_hourly_race(timestamptz) from public, anon, authenticated;
revoke all on function public.settle_due_hourly_races() from public, anon, authenticated;
revoke all on function public.get_hourly_race() from public, anon, authenticated;
revoke all on function public.claim_hourly_race_reward(uuid) from public, anon, authenticated;
grant execute on function public.get_hourly_race() to anon, authenticated;
grant execute on function public.register_hourly_race_team(timestamptz, text[]) to authenticated;
grant execute on function public.settle_due_hourly_races() to authenticated;
grant execute on function public.claim_hourly_race_reward(uuid) to authenticated;
