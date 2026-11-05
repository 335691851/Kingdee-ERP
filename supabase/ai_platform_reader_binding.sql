-- Login is provisioned separately with a random password through a secure channel.
-- No credentials belong in this file. Applied state verified 2026-11-05.
BEGIN;
GRANT erp_ai_reader TO erp_aip_runtime;
ALTER ROLE erp_aip_runtime SET default_transaction_read_only=on;
GRANT SELECT ON public.material_category TO erp_ai_reader;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public'
 AND tablename='material_category' AND policyname='erp_ai_reader_select') THEN
  CREATE POLICY erp_ai_reader_select ON public.material_category
  FOR SELECT TO erp_ai_reader USING(true);
 END IF;
END $$;
COMMIT;
