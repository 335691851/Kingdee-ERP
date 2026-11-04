-- Precise scopes for existing priced contracts; explicitly simulated scope for
-- the 100 service frameworks in the reviewed synthetic batch. Preserve prices.
BEGIN;
INSERT INTO contract_sku(contract_id,material_id)
SELECT DISTINCT contract_id,material_id FROM contract_price
ON CONFLICT(contract_id,material_id) DO NOTHING;

INSERT INTO contract_category(contract_id,category_id)
SELECT c.id,x.category_id FROM sales_contract c
JOIN LATERAL (
 SELECT DISTINCT m.category_id FROM material_org mo JOIN material m ON m.id=mo.material_id
 WHERE mo.company_id=c.company_id AND m.kind='product' AND m.classification_status='classified'
) candidates ON true
JOIN LATERAL (
 SELECT category_id,row_number() OVER(ORDER BY category_id)-1 idx,count(*) OVER() n
 FROM (SELECT DISTINCT m.category_id FROM material_org mo JOIN material m ON m.id=mo.material_id WHERE mo.company_id=c.company_id AND m.kind='product' AND m.classification_status='classified') a
) x ON x.category_id=candidates.category_id AND x.idx=(right(c.contract_no,4)::int/40)%x.n
WHERE c.kind='service' AND c.contract_no LIKE 'SIM-HT-20261104-%' AND c.notes LIKE '批次：contract_sim_20261104_v1%' AND right(c.contract_no,4)::int%40 IN (0,1)
ON CONFLICT(contract_id,category_id) DO NOTHING;

INSERT INTO contract_sku(contract_id,material_id)
SELECT c.id,m.id FROM sales_contract c
CROSS JOIN LATERAL generate_series(0,right(c.contract_no,4)::int%2) l(i)
JOIN LATERAL (
 SELECT m.id,row_number() OVER(ORDER BY m.id)-1 idx,count(*) OVER() n
 FROM material_org mo JOIN material m ON m.id=mo.material_id
 WHERE mo.company_id=c.company_id AND m.kind='product' AND m.classification_status='classified'
) m ON m.idx=(right(c.contract_no,4)::int*3+l.i)%m.n
WHERE c.kind='service' AND c.contract_no LIKE 'SIM-HT-20261104-%' AND c.notes LIKE '批次：contract_sim_20261104_v1%' AND right(c.contract_no,4)::int%40 IN (20,21)
ON CONFLICT(contract_id,material_id) DO NOTHING;

WITH changed AS (
 UPDATE sales_contract c SET version=version+1,updated_at=to_char(now() AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD"T"HH24:MI:SS')||'+08:00',
 notes=notes||'；产品适用范围于2026-11-04补充：商品合同按价格明细SKU，服务合同的分类/SKU范围为模拟设计。原PDF保留历史，新版明确标注产品范围。'
 WHERE c.contract_no LIKE 'SIM-HT-20261104-%' AND c.notes LIKE '批次：contract_sim_20261104_v1%' AND NOT EXISTS(SELECT 1 FROM contract_event e WHERE e.contract_id=c.id AND e.action='scope_backfill')
 RETURNING id,owner_id,updated_at
)
INSERT INTO contract_event(contract_id,actor_id,action,note,created_at)
SELECT id,owner_id,'scope_backfill','应用户要求补充模拟合同的产品分类/SKU范围；不改变原商品价格及审核状态；保留旧PDF并补充新版',updated_at FROM changed;
COMMIT;
