BEGIN;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='erp_ai_reader') THEN CREATE ROLE erp_ai_reader NOLOGIN; END IF; END $$;
GRANT USAGE ON SCHEMA public TO erp_ai_reader;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['company','material','uom','lot','stock_balance','stock_transaction','document','document_line','delivery_schedule','bom','production_detail','sales_contract','contract_customer','contract_sku','contract_category','contract_attachment','document_link','voucher','voucher_line','gl_account','ai_restock_source','ai_integration_scenario'] LOOP
 EXECUTE format('GRANT SELECT ON public.%I TO erp_ai_reader',t);
 EXECUTE format('CREATE POLICY erp_ai_reader_select ON public.%I FOR SELECT TO erp_ai_reader USING (true)',t);
 END LOOP;
END $$;
GRANT SELECT ON public.ai_restock_plan_input TO erp_ai_reader;
COMMIT;
-- After the platform supplies its dedicated LOGIN role, grant erp_ai_reader to it.
-- Do not grant this group to anon/authenticated or reuse the application admin name.
