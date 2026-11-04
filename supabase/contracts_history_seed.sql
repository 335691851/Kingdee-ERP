-- 1000 synthetic contract forms as of 2026-11-04. No real agreement/signature.
-- Idempotent: fills only this batch; never overwrites existing contracts.
BEGIN;
SET LOCAL search_path=public;
CREATE TEMP TABLE contract_seed_map ON COMMIT DROP AS
WITH assignment AS (
 SELECT g, CASE WHEN g<=350 THEN '0301' WHEN g<=650 THEN '030'||(2+(g-351)/75)::text
 ELSE lpad((306+(g-651)/50)::text,4,'0') END company_code
 FROM generate_series(1,1000) g
), base AS (
 SELECT a.g,c.id company_id,c.code,c.name company_name,o.id organization_id,e.id salesperson_id,u.id owner_id,
 'SIM-HT-20261104-'||lpad(a.g::text,4,'0') contract_no,
 CASE WHEN a.g%20 IN (0,1) THEN 'service' WHEN a.g%20 BETWEEN 2 AND 6 THEN 'mixed' ELSE 'goods' END kind,
 DATE '2026-11-04'-CASE WHEN a.g>950 THEN a.g%7 WHEN a.g>900 THEN a.g%15 ELSE 20+(a.g*137)%345 END signed_date
 FROM assignment a JOIN company c ON c.code=a.company_code
 JOIN LATERAL (SELECT id FROM organization WHERE company_id=c.id ORDER BY id LIMIT 1) o ON true
 JOIN LATERAL (SELECT e.id FROM employee e JOIN department d ON d.id=e.department_id WHERE e.company_id=c.id AND d.name='营销部' ORDER BY e.id LIMIT 1) e ON true
 JOIN LATERAL (SELECT a.id FROM app_user a JOIN membership m ON m.user_id=a.id WHERE a.name='admin' AND a.enabled AND m.company_id=c.id AND m.role='admin' ORDER BY a.id LIMIT 1) u ON true
)
SELECT *,signed_date+3 valid_from_date,signed_date+3+(ARRAY[30,90,180,365])[1+g%4] valid_to_date,
 CASE WHEN g>950 THEN 'draft' WHEN g>900 THEN 'submitted' WHEN ((g-1)/20+(g-1)%20)%10=0 THEN 'terminated' WHEN ((g-1)/20+(g-1)%20)%10=1 THEN 'rejected' ELSE 'approved' END final_status
FROM base;
DO $$ BEGIN
 IF (SELECT count(*) FROM contract_seed_map)<>1000 THEN RAISE EXCEPTION 'Missing company, organization, sales employee or admin scope'; END IF;
END $$;
INSERT INTO sales_contract(company_id,organization_id,contract_no,title,kind,salesperson_id,owner_id,signed_on,valid_from,valid_to,payment_terms,service_terms,notes,status,version,created_at,updated_at)
SELECT company_id,organization_id,contract_no,
 CASE kind WHEN 'goods' THEN '盐品购销及阶梯价格协议' WHEN 'service' THEN '渠道客户履约服务框架协议' ELSE '盐品供货与渠道服务综合协议' END||'（模拟）-'||to_char(signed_date,'YYYYMM')||'-'||lpad(g::text,4,'0'),
 kind,salesperson_id,owner_id,signed_date::text,valid_from_date::text,valid_to_date::text,
 (ARRAY['款到安排发货，双方每月对账；不设无条件赊销额度。','货到验收后30天内付款，每月5日前完成上月对账。','预付30%，货到验收后15天内结清尾款。','按月结算，验收及对账完成后45天内付款。'])[1+g%4],
 '【模拟协议，不构成真实交易或法律文件】'||chr(10)||
 '一、适用范围：仅适用于本表勾选的客户及本合同编号对应项目，不自动扩展至其他客户、法人或地区。'||chr(10)||
 CASE kind WHEN 'service' THEN '二、服务内容：提供订单协调、客户培训、质量追溯资料、售后回访及月度履约报告；具体服务须经客户书面确认。服务费用另行确认，本表不虚构按吨服务收费。'
 ELSE '二、供货范围：按商品明细中的物料编码、型号规格、包装和数量区间执行协议单价；未列示商品另行协商。目录价格为当前ERP模拟参数，优惠幅度为合成设定，不代表真实历史成交价。' END||chr(10)||
 '三、交付约定：'||(ARRAY['订单确认后3个工作日内安排交付，具体以双方确认的计划为准。','按周滚动提报需求，提前5个工作日确认交付数量和批次。','按月制定供货计划，临时增量需双方另行确认。'])[1+g%3]||chr(10)||
 '四、质量与验收：核对品名、规格、批次及数量；食品、药用、饲料与工业用途分别管理，不得混用。质量标准按双方确认的产品资料执行；收货后3个工作日内反馈数量及包装问题，质量异议留存批次与样品。'||chr(10)||
 '五、费用及税价：明细逐行记录含税与税率口径；所列税率仅为模拟数据。'||(ARRAY['本协议商品价不含配送费，运费单独对账，避免重复计价。','本协议按客户自提口径，不计销售运费；额外服务另行确认。'])[1+g%2]||chr(10)||
 '六、责任与变更：发生交付或质量异常时及时通知并协商处理；任何价格、客户范围和有效期变更应留存书面补充材料。期限届满后需重新确认，不自动续期。双方保密义务按约定执行。'||chr(10)||
 '七、模拟声明：未生成公章、签名、银行账户、真实联系人或真实签署凭证，不得用于对外签约或结算。',
 '批次：contract_sim_20261104_v1；关联现有ERP法人、客户授权、成品物料和模拟目录价格；业务日期及状态为近一年合成历史。由管理员统一导入，销售人员为业务责任字段，并非实际员工操作记录。PDF文件实际生成及上传日为2026-11-04；业务时间模拟。'||CASE WHEN company_id>=7 THEN '当前公司名称沿用ERP简称，法人全称待确认，不补造工商信息。' ELSE '' END,
 'draft',1,signed_date::text||'T08:00:00+08:00',signed_date::text||'T08:00:00+08:00'
FROM contract_seed_map
ON CONFLICT(company_id,contract_no) DO NOTHING;

INSERT INTO contract_customer(contract_id,partner_id)
SELECT c.id,p.id FROM contract_seed_map b JOIN sales_contract c ON c.company_id=b.company_id AND c.contract_no=b.contract_no
JOIN LATERAL (
 SELECT p.id,row_number() OVER(ORDER BY CASE WHEN p.related_company_id IS NULL THEN 1 ELSE 0 END,p.id)-1 idx,count(*) OVER() n
 FROM partner_role pr JOIN partner p ON p.id=pr.partner_id
 WHERE pr.company_id=b.company_id AND pr.role='customer' AND (p.related_company_id IS NULL OR p.related_company_id<>b.company_id)
) p ON (p.idx-(b.g*7)%p.n+p.n)%p.n < 1+b.g%3
ON CONFLICT(contract_id,partner_id) DO NOTHING;

INSERT INTO contract_price(contract_id,line_no,material_id,unit_price_cents,min_qty,max_qty,tax_rate,includes_tax,remark)
SELECT c.id,l.line_no,m.id,round(m.list_price_cents*(ARRAY[0.92,0.95,0.97,1.00,1.03,1.05]::numeric[])[1+(b.g+l.line_no)%6])::bigint,
 (ARRAY[1,10,50,200])[1+b.g%4],(ARRAY[10,50,200,NULL::int])[1+b.g%4],
 CASE WHEN m.category='药用盐' THEN .13 ELSE .09 END,true,
 '模拟协议价；元/吨；当前目录价调整比例 '||((ARRAY[-8,-5,-3,0,3,5])[1+(b.g+l.line_no)%6])::text||'%；仅适用于本合同客户及项目；税率为演示设定。'
FROM contract_seed_map b JOIN sales_contract c ON c.company_id=b.company_id AND c.contract_no=b.contract_no
CROSS JOIN LATERAL generate_series(1,1+b.g%3) l(line_no)
JOIN LATERAL (
 SELECT m.id,m.list_price_cents,mc.name category,row_number() OVER(ORDER BY m.id)-1 idx,count(*) OVER() n
 FROM material_org mo JOIN material m ON m.id=mo.material_id JOIN material_category mc ON mc.id=m.category_id
 WHERE mo.company_id=b.company_id AND m.kind='product' AND m.classification_status='classified'
) m ON m.idx=(b.g*5+l.line_no-1)%m.n
WHERE b.kind<>'service'
ON CONFLICT(contract_id,line_no) DO NOTHING;

INSERT INTO contract_event(contract_id,actor_id,action,note,created_at)
SELECT c.id,b.owner_id,'create','模拟历史导入；不是实际提交记录；批次 contract_sim_20261104_v1',c.created_at
FROM contract_seed_map b JOIN sales_contract c ON c.company_id=b.company_id AND c.contract_no=b.contract_no
WHERE NOT EXISTS(SELECT 1 FROM contract_event e WHERE e.contract_id=c.id AND e.action='create');
COMMIT;
