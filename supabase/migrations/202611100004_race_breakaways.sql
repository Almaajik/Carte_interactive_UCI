alter table public.race_events
  add column if not exists escape_probability smallint not null default 30;

alter table public.race_events
  add constraint race_events_escape_probability_check
  check (escape_probability between 0 and 100);

alter table public.daily_races
  add column if not exists race_result jsonb;

update public.race_events
set escape_probability = case
  when climb_pct >= 28 then 50
  when climb_pct >= 12 then 30
  else 10
end;

create or replace function public.settle_race(p_race_date date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_race public.daily_races%rowtype;
  v_race_name text;
  v_escape_probability integer;
  v_unique_riders integer;
  v_breakaway_size integer;
  v_breakaway_ids text[];
  v_finish_ids text[];
  v_breakaway_riders jsonb := '[]'::jsonb;
  v_race_result jsonb;
  v_breakaway_won boolean := false;
  v_entry record;
  v_boosters integer;
  v_award_total integer;
begin
  select * into v_race
    from public.daily_races
    where race_date = p_race_date
    for update;
  if not found or v_race.settled_at is not null then
    return;
  end if;
  if now() < (v_race.race_date + time '20:00') at time zone 'Europe/Paris' then
    return;
  end if;
  select events.name, events.escape_probability
    into v_race_name, v_escape_probability
    from public.race_events as events
    where events.slug = v_race.race_slug;

  select count(distinct submitted.rider_id)
    into v_unique_riders
    from public.race_entries as entries
    cross join lateral unnest(entries.rider_ids) as submitted(rider_id)
    where entries.race_date = p_race_date;

  if v_unique_riders >= 3 and random() * 100 < v_escape_probability then
    v_breakaway_won := true;
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
            from public.race_entries as entries
            cross join lateral unnest(entries.rider_ids) as submitted(rider_id)
            where entries.race_date = p_race_date
          ) as candidates
          order by random()
          limit v_breakaway_size
        ) as drawn
        join public.rider_scores as scores using (rider_id)
        cross join public.race_events as events
        where events.slug = v_race.race_slug
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
  end if;

  v_race_result := jsonb_build_object(
    'breakaway_won', v_breakaway_won,
    'escape_probability', v_escape_probability,
    'breakaway_riders', v_breakaway_riders,
    'finish_top3', case when v_breakaway_won then v_breakaway_riders else '[]'::jsonb end,
    'winner', case when v_breakaway_won then v_breakaway_riders->0 else null end,
    'team_bonus', jsonb_build_array(30, 20, 10),
    'settled_at', now()
  );
  update public.daily_races
    set race_result = v_race_result
    where race_date = p_race_date;

  update public.race_entries as entries
    set score = public.score_race_team(entries.race_date, entries.rider_ids)
      + coalesce((
        select sum(case places.finish_place when 1 then 30 when 2 then 20 when 3 then 10 else 0 end)::integer
        from unnest(entries.rider_ids) as submitted(rider_id)
        join unnest(v_finish_ids) with ordinality as places(rider_id, finish_place)
          using (rider_id)
      ), 0)
    where entries.race_date = p_race_date;

  for v_entry in
    with standings as (
      select user_id, score,
        rank() over (order by score desc)::integer as place,
        count(*) over (partition by score)::integer as tied,
        row_number() over (partition by score order by user_id)::integer as tie_order
      from public.race_entries
      where race_date = p_race_date
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
          else '' end
        || case when v_breakaway_won then
          ' · Échappée victorieuse : ' || (v_race_result->'winner'->>'rider_name') || '.'
          else ' · Le peloton a repris l’échappée avant l’arrivée.' end,
      20, v_boosters
    )
    on conflict (race_date, user_id) do nothing;
  end loop;
  update public.daily_races set settled_at = now() where race_date = p_race_date;
end;
$$;
