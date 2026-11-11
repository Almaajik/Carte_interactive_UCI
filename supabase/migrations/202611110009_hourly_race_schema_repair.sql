alter table public.hourly_races
  add column if not exists breakaway_won boolean not null default false,
  add column if not exists race_plan jsonb not null default '{}'::jsonb,
  add column if not exists race_result jsonb,
  add column if not exists settled_at timestamptz,
  add column if not exists created_at timestamptz not null default now();

grant select (slot_start, race_slug, race_plan, race_result, settled_at, created_at)
  on public.hourly_races to anon, authenticated;

notify pgrst, 'reload schema';
