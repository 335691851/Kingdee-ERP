-- Fixed as-of date for reproducible one-year historical simulation.
WITH params AS (SELECT DATE '2026-11-04' AS asof),
companies AS (SELECT ordinality::int-1 idx,value v FROM jsonb_array_elements('[{"code": "0306", "name": "山东省鲁盐集团菏泽有限公司", "confirmed": true, "region": "省内部菏泽区", "city": "菏泽市"}, {"code": "0307", "name": "鲁盐泰安", "confirmed": false, "region": "泰安区域", "city": "泰安市"}, {"code": "0308", "name": "鲁盐鲁南", "confirmed": false, "region": "鲁南区域", "city": "临沂市"}, {"code": "0309", "name": "鲁盐鲁中", "confirmed": false, "region": "鲁中区域", "city": "淄博市"}, {"code": "0310", "name": "鲁盐潍坊", "confirmed": false, "region": "潍坊区域", "city": "潍坊市"}, {"code": "0311", "name": "鲁盐济宁", "confirmed": false, "region": "济宁区域", "city": "济宁市"}, {"code": "0312", "name": "鲁盐滕州", "confirmed": false, "region": "滕州区域", "city": "滕州市"}]'::jsonb) WITH ORDINALITY),
products AS (SELECT ordinality::int-1 idx,value v FROM jsonb_array_elements('[{"code": "09020101106", "name": "鲁晶-精制盐-菏泽高山新-400g-小包-平袋-未加碘-箱装-20kg", "model": "食用盐", "spec": "400g-20kg", "origin": "unknown", "pack": "small", "packkg": 20.0, "price": 1050.0, "level1": "食用盐", "level2": "小包装"}, {"code": "09020101105", "name": "鲁晶-精制盐-菏泽-400g-小包-平袋-未加碘-箱装-20kg", "model": "食用盐", "spec": "400g-20kg", "origin": "unknown", "pack": "small", "packkg": 20.0, "price": 1050.0, "level1": "食用盐", "level2": "小包装"}, {"code": "09020101150", "name": "鲁祥-精制盐-400g-小包-平袋-未加碘-袋装-20kg", "model": "食用盐", "spec": "400g-20kg", "origin": "unknown", "pack": "small", "packkg": 20.0, "price": 650.0, "level1": "食用盐", "level2": "小包装"}, {"code": "11001", "name": "鲁祥-药品氯化钠-大包-袋装-25Kg", "model": "医药盐", "spec": "25kg", "origin": "unknown", "pack": "large", "packkg": 25.0, "price": 2300.0, "level1": "非食用盐", "level2": "药用盐"}, {"code": "09020102007", "name": "嘉义安-海藻盐-500g-平袋-加碘-袋装20kg", "model": "食用盐", "spec": "500g-20kg", "origin": "unknown", "pack": "small", "packkg": 20.0, "price": 1250.0, "level1": "食用盐", "level2": "小包装"}, {"code": "09020109002", "name": "东岳-纳钾调味盐-400g-小包-立袋-箱装-20kg", "model": "调味盐", "spec": "400g-20kg", "origin": "unknown", "pack": "small", "packkg": 20.0, "price": 1650.0, "level1": "食用盐", "level2": "小包装"}, {"code": "09020202013", "name": "东岳-绿色低钠盐-320g-立袋-加碘-箱装19.2kg", "model": "低钠盐", "spec": "320g-19.2kg", "origin": "unknown", "pack": "small", "packkg": 19.2, "price": 2100.0, "level1": "食用盐", "level2": "小包装"}, {"code": "DEMO-F001", "name": "食品加工用盐-大包-25kg（模拟新增）", "model": "食品加工用盐", "spec": "25kg", "origin": "unknown", "pack": "large", "packkg": 25.0, "price": 580.0, "level1": "食用盐", "level2": "食品加工用盐"}, {"code": "DEMO-N001", "name": "精工饲料盐-大包-50kg（模拟新增）", "model": "精工饲料盐", "spec": "50kg", "origin": "unknown", "pack": "large", "packkg": 50.0, "price": 460.0, "level1": "非食用盐", "level2": "精工饲料盐"}, {"code": "DEMO-N002", "name": "散湿盐-散装（模拟新增）", "model": "散湿盐", "spec": "散装", "origin": "unknown", "pack": "bulk", "packkg": null, "price": 360.0, "level1": "非食用盐", "level2": "散湿盐"}, {"code": "DEMO-N003", "name": "海盐散原盐-散装（模拟新增）", "model": "海盐散原盐", "spec": "散装", "origin": "sea", "pack": "bulk", "packkg": null, "price": 330.0, "level1": "非食用盐", "level2": "海盐散原盐"}, {"code": "DEMO-N004", "name": "软水剂-大包-25kg（模拟新增）", "model": "软水剂", "spec": "25kg", "origin": "unknown", "pack": "large", "packkg": 25.0, "price": 820.0, "level1": "非食用盐", "level2": "软水剂"}]'::jsonb) WITH ORDINALITY),
base AS (
 SELECT g,c.v c,m.v m,p.asof,
 ((p.asof-365+((g-1)*364/1199)::int)+time '08:00'+make_interval(hours=>g%8)) AT TIME ZONE 'Asia/Shanghai' applied,
 CASE WHEN g>1170 THEN 'submitted' WHEN g%10=0 THEN 'withdrawn' WHEN g%10 IN (1,2) THEN 'rejected' ELSE 'approved' END state,
 (ARRAY[-0.12,-0.10,-0.08,-0.06,-0.05,-0.03,0.02,0.04]::numeric[])[1+(g%8)] delta,
 g%4 tier
 FROM generate_series(1,1200) g CROSS JOIN params p JOIN companies c ON c.idx=(g-1)%7 JOIN products m ON m.idx=((g-1)/7)%12
), valueset AS (
 SELECT *, (m->>'price')::numeric original,
 round((m->>'price')::numeric*(1+delta),2) requested,
 CASE tier WHEN 0 THEN 1 WHEN 1 THEN 10 WHEN 2 THEN 50 ELSE 200 END lo,
 CASE tier WHEN 0 THEN 10 WHEN 1 THEN 50 WHEN 2 THEN 200 ELSE NULL END hi,
 CASE tier WHEN 0 THEN 2+g%7 WHEN 1 THEN 10+g%40 WHEN 2 THEN 50+g%150 ELSE 200+g%401 END qty,
 applied+interval '3 days' vf,
 applied+interval '3 days'+make_interval(days=> (ARRAY[15,30,60,90])[1+g%4]) vt
 FROM base
)
INSERT INTO public.pricechangerecord (
 application_no,group_company_code,group_company_name,applicant_company_code,applicant_company_name,applicant_legal_name_confirmed,applicant_relationship_note,
 sales_region,city,category_level1,category_level2,material_code,material_name,model,specification,salt_origin,packaging,pack_weight_kg,
 weight_scale,min_quantity_ton,max_quantity_ton,requested_quantity_ton,original_price,requested_price,approved_price,
 application_scope,project_code,application_reason,applied_at,valid_from,valid_to,status,completed_at,review_note,is_simulated,source_basis,seed_batch,snapshot_as_of
)
SELECT 'TJ-SIM-'||to_char(applied AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'-'||lpad(g::text,5,'0'),
 '0301','山东省鲁盐集团有限公司',c->>'code',c->>'name',(c->>'confirmed')::boolean,
 '按ERP关联营销法人模拟特殊价格申请主体；合资股权属性未核实；简称未补造法人全称',
 c->>'region',c->>'city',m->>'level1',m->>'level2',m->>'code',m->>'name',m->>'model',m->>'spec',m->>'origin',m->>'pack',(m->>'packkg')::numeric,
 (ARRAY['1至不足10吨','10至不足50吨','50至不足200吨','200吨及以上'])[1+tier],lo,hi,qty,original,requested,
 CASE WHEN state='approved' THEN requested ELSE NULL END,
 '仅对应区域专项项目，不作为全区域统一价格','DEMO-PC-'||lpad(g::text,5,'0'),
 CASE WHEN delta>0 THEN '模拟：包装或履约成本上升，申请专项价格上调' WHEN tier>=2 THEN '模拟：批量采购，申请阶梯优惠' ELSE '模拟：区域竞争或促销专项价格支持' END,
 applied,vf,vt,state,CASE WHEN state='submitted' THEN NULL ELSE applied+make_interval(hours=>12+g%36) END,
 CASE state WHEN 'approved' THEN '模拟审批通过，执行价等于申请价，仅限本项目及有效期' WHEN 'rejected' THEN '模拟驳回：折扣支持依据不足，不执行申请价' WHEN 'withdrawn' THEN '模拟撤回：项目采购计划调整，不执行申请价' ELSE '模拟待审批，不执行申请价' END,
 true,'本地已交付ERP app/catalog.py及app/materials.py公司/物料/分类/目录价快照；区域、吨位、调价、审批、时间为合成；目录价不是历史成交价；含税13%，不含运费',
 'pricechange_sim_20261104_v1',asof
FROM valueset
ON CONFLICT (application_no) DO NOTHING;
