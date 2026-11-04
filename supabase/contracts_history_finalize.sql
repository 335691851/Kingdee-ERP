-- Finalize simulated workflow ONLY after every PDF has been uploaded successfully.
BEGIN;
SET LOCAL search_path=public;
DO $$ BEGIN
 IF (SELECT count(*) FROM sales_contract WHERE contract_no LIKE 'SIM-HT-20261104-%' AND notes LIKE '批次：contract_sim_20261104_v1%')<>1000 THEN RAISE EXCEPTION 'Expected exactly 1000 simulation forms'; END IF;
 IF EXISTS(SELECT 1 FROM sales_contract c WHERE c.contract_no LIKE 'SIM-HT-20261104-%' AND NOT EXISTS(SELECT 1 FROM contract_attachment a WHERE a.contract_id=c.id AND a.filename=c.contract_no||'.pdf')) THEN RAISE EXCEPTION 'Missing simulated PDF attachments'; END IF;
END $$;
CREATE TEMP TABLE contract_history_states ON COMMIT DROP AS
SELECT *,CASE WHEN g>950 THEN 'draft' WHEN g>900 THEN 'submitted' WHEN ((g-1)/20+(g-1)%20)%10=0 THEN 'terminated' WHEN ((g-1)/20+(g-1)%20)%10=1 THEN 'rejected' ELSE 'approved' END final_state
FROM (SELECT c.*,right(contract_no,4)::int g FROM sales_contract c WHERE contract_no LIKE 'SIM-HT-20261104-%' AND notes LIKE '批次：contract_sim_20261104_v1%') x;

UPDATE contract_attachment a SET created_at=c.signed_on||'T09:00:00+08:00'
FROM contract_history_states c WHERE a.contract_id=c.id AND a.filename=c.contract_no||'.pdf';
UPDATE contract_event e SET created_at=c.signed_on||'T09:00:00+08:00',note=c.contract_no||'.pdf；模拟历史业务时间，文件实际生成及上传日为2026-11-04'
FROM contract_history_states c WHERE e.contract_id=c.id AND e.action='upload';

INSERT INTO contract_event(contract_id,actor_id,action,note,created_at)
SELECT c.id,c.owner_id,'submit','模拟历史：客户范围、价格表与附件提交审核；非实际员工操作',c.signed_on||'T10:00:00+08:00'
FROM contract_history_states c WHERE final_state<>'draft' AND NOT EXISTS(SELECT 1 FROM contract_event e WHERE e.contract_id=c.id AND e.action='submit');
INSERT INTO contract_event(contract_id,actor_id,action,note,created_at)
SELECT c.id,c.owner_id,'approve','模拟历史：协议价格及履约条款审核通过，仅用于演示；不是实际审批',c.signed_on||'T11:00:00+08:00'
FROM contract_history_states c WHERE final_state IN ('approved','terminated') AND NOT EXISTS(SELECT 1 FROM contract_event e WHERE e.contract_id=c.id AND e.action='approve');
INSERT INTO contract_event(contract_id,actor_id,action,note,created_at)
SELECT c.id,c.owner_id,'reject',CASE WHEN c.g%3=0 THEN '模拟历史退回：请补充价格适用数量区间依据' WHEN c.g%3=1 THEN '模拟历史退回：请明确售后服务范围与交付验收标准' ELSE '模拟历史退回：付款条件与客户信用约定需进一步确认' END,c.signed_on||'T11:00:00+08:00'
FROM contract_history_states c WHERE final_state='rejected' AND NOT EXISTS(SELECT 1 FROM contract_event e WHERE e.contract_id=c.id AND e.action='reject');
INSERT INTO contract_event(contract_id,actor_id,action,note,created_at)
SELECT c.id,c.owner_id,'terminate','模拟历史终止：客户采购计划调整，双方不再按此框架继续履约；后续需重新确认',least(c.signed_on::date+30,DATE '2026-11-03')::text||'T12:00:00+08:00'
FROM contract_history_states c WHERE final_state='terminated' AND NOT EXISTS(SELECT 1 FROM contract_event e WHERE e.contract_id=c.id AND e.action='terminate');

UPDATE sales_contract c SET status=b.final_state,
version=greatest(c.version,CASE b.final_state WHEN 'draft' THEN 2 WHEN 'submitted' THEN 3 WHEN 'terminated' THEN 5 ELSE 4 END),
updated_at=CASE b.final_state WHEN 'draft' THEN b.signed_on||'T09:00:00+08:00' WHEN 'submitted' THEN b.signed_on||'T10:00:00+08:00' WHEN 'terminated' THEN least(b.signed_on::date+30,DATE '2026-11-03')::text||'T12:00:00+08:00' ELSE b.signed_on||'T11:00:00+08:00' END
FROM contract_history_states b WHERE c.id=b.id;
COMMIT;
