alter table public.user_collections
  alter column payload
  set default '{"riders":{},"drops":0,"freeDate":"","packsOpened":0,"lastPack":[]}'::jsonb;
