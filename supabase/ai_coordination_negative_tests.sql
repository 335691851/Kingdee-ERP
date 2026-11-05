BEGIN;
CREATE TABLE ai_integration_validation(case_id text PRIMARY KEY, tested_at timestamptz NOT NULL DEFAULT now(),passed boolean NOT NULL, evidence jsonb NOT NULL);
ALTER TABLE ai_integration_validation ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ai_integration_validation FROM anon,authenticated;
DO $$
DECLARE r ai_restock_source%ROWTYPE; base ai_integration_scenario%ROWTYPE; n int;
BEGIN
 SELECT * INTO base FROM ai_integration_scenario WHERE scenario_id='R01';
 INSERT INTO ai_integration_scenario SELECT 'R09',run_date,company_id,material_id,source_material_id,lot_id,'{"hit":false,"rejected":"重复工厂SKU快照"}'::jsonb,'联调模拟＋R09；约束拒绝，不保留重复来源',true FROM ai_integration_scenario WHERE scenario_id='R01';
 SELECT * INTO r FROM ai_restock_source WHERE scenario_id='R01'; r.scenario_id='R09';
 BEGIN
 INSERT INTO ai_restock_source SELECT r.*;
 RAISE EXCEPTION 'Duplicate source was not rejected';
 EXCEPTION WHEN unique_violation THEN INSERT INTO ai_integration_validation VALUES('R09',now(),true,'{"reason":"数据库唯一约束拒绝同工厂SKU快照的重复窗口，未进入输入视图"}'); END;
 INSERT INTO ai_integration_scenario SELECT 'R10',run_date,company_id,material_id,source_material_id,lot_id,'{"hit":false,"rejected":"负数量"}'::jsonb,'联调模拟＋R10；约束拒绝，不保留负数来源',true FROM ai_integration_scenario WHERE scenario_id='R01';
 r.scenario_id='R10'; r.transit_qty=-1;
 BEGIN INSERT INTO ai_restock_source SELECT r.*; RAISE EXCEPTION 'Negative source accepted';
 EXCEPTION WHEN check_violation THEN INSERT INTO ai_integration_validation VALUES('R10-negative',now(),true,'{"reason":"数据库CHECK拒绝负在途量"}'); END;
 r.transit_qty=NULL;
 BEGIN INSERT INTO ai_restock_source SELECT r.*; RAISE EXCEPTION 'Null source accepted';
 EXCEPTION WHEN not_null_violation THEN INSERT INTO ai_integration_validation VALUES('R10-null',now(),true,'{"reason":"数据库NOT NULL拒绝缺失数量"}'); END;
 r.transit_qty=15;r.source_refs='';
 BEGIN INSERT INTO ai_restock_source SELECT r.*; RAISE EXCEPTION 'Empty source accepted';
 EXCEPTION WHEN check_violation THEN INSERT INTO ai_integration_validation VALUES('R10-source',now(),true,'{"reason":"数据库CHECK拒绝空来源"}'); END;
 r.source_refs='联调模拟＋R10；非法窗口测试';r.plan_start=r.plan_end+1;
 BEGIN INSERT INTO ai_restock_source SELECT r.*; RAISE EXCEPTION 'Reversed window accepted';
 EXCEPTION WHEN check_violation THEN INSERT INTO ai_integration_validation VALUES('R10-date',now(),true,'{"reason":"数据库CHECK拒绝开始日晚于结束日"}'); END;
 BEGIN
 UPDATE ai_restock_source SET company_id=7 WHERE scenario_id='R01';
 SELECT count(*) INTO n FROM ai_restock_plan_input WHERE material_id=base.material_id;
 IF n<>0 THEN RAISE EXCEPTION 'Marketing company leaked into view'; END IF;
 RAISE EXCEPTION USING ERRCODE='Z0001',MESSAGE='Rollback isolated marketing test';
 EXCEPTION WHEN SQLSTATE 'Z0001' THEN INSERT INTO ai_integration_validation VALUES('R11',now(),true,'{"reason":"隔离事务验证营销法人输入不出现在工厂视图；测试修改已回滚"}'); END;
 INSERT INTO ai_integration_validation VALUES('T11',now(),true,jsonb_build_object('fixture_only',true,'qty',0.20,'manufactured_on',(base.run_date-interval '6 months')::date,'first_positive_inbound',NULL,'expected_hit',false,'reason','无可查正向入库证据，生产日期不能替代；不向正式余额植入无流水库存'));
END $$;
COMMIT;
