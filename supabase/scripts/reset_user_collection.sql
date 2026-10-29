-- Replace this value with the exact email address of the account to reset.
DO $reset_collection$
DECLARE
  target_email text := 'REMPLACER_PAR_EMAIL';
  target_user_id uuid;
  empty_collection jsonb := '{"riders":{},"dust":0,"freeDate":"","packsOpened":0,"lastPack":[]}'::jsonb;
BEGIN
  IF target_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Set target_email to a valid account email before running this script.';
  END IF;

  SELECT id
  INTO STRICT target_user_id
  FROM auth.users
  WHERE lower(email) = lower(target_email);

  INSERT INTO public.user_collections (user_id, payload, updated_at)
  VALUES (target_user_id, empty_collection, now())
  ON CONFLICT (user_id) DO UPDATE
  SET payload = EXCLUDED.payload,
      updated_at = EXCLUDED.updated_at;

  RAISE NOTICE 'Collection reset for %.', target_email;
END
$reset_collection$;