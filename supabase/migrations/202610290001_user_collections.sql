create table if not exists public.user_collections (
  user_id uuid primary key references auth.users (id) on delete cascade,
  payload jsonb not null default '{"riders":{},"dust":0,"freeDate":"","packsOpened":0,"lastPack":[]}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint user_collections_payload_size check (pg_column_size(payload) <= 900000),
  constraint user_collections_payload_object check (jsonb_typeof(payload) = 'object')
);

alter table public.user_collections enable row level security;
revoke all on table public.user_collections from anon, authenticated;
grant select, insert, update on table public.user_collections to authenticated;

drop policy if exists "Users can read their own collection" on public.user_collections;
drop policy if exists "Users can create their own collection" on public.user_collections;
drop policy if exists "Users can update their own collection" on public.user_collections;

create policy "Users can read their own collection"
  on public.user_collections for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can create their own collection"
  on public.user_collections for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users can update their own collection"
  on public.user_collections for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);