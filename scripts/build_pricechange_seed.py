"""Generate standalone SQL snapshots from delivered ERP definitions (no DB connection)."""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app.catalog import COMPANIES
from app.materials import material_definitions,CATEGORIES

def build():
    regions=[('省内部菏泽区','菏泽市'),('泰安区域','泰安市'),('鲁南区域','临沂市'),('鲁中区域','淄博市'),('潍坊区域','潍坊市'),('济宁区域','济宁市'),('滕州区域','滕州市')]
    companies=[dict(code=c[0],name=c[1],confirmed=c[3],region=r[0],city=r[1]) for c,r in zip(COMPANIES[5:],regions)]
    categories={c[0]:c for c in CATEGORIES}
    products=[]
    for m in material_definitions():
        if m['kind']!='product' or m['classification_status']!='classified':continue
        cat=categories[m['category_id']]
        products.append(dict(code=m['code'],name=m['name'],model=m['product_feature'],spec=m['spec'],origin=m['salt_origin'],pack=m['packaging'],packkg=None if m['packaging']=='bulk' else float(m['spec'].split('-')[-1].lower().replace('kg','')),price=m['list_price_cents']/100,level1=categories[cat[3]][2],level2=cat[2]))
    def literal(value):return "'"+json.dumps(value,ensure_ascii=False).replace("'","''")+"'::jsonb"
    sql="""-- Fixed as-of date for reproducible one-year historical simulation.
WITH params AS (SELECT DATE '2026-11-04' AS asof),
companies AS (SELECT ordinality::int-1 idx,value v FROM jsonb_array_elements(COMPANIES_JSON) WITH ORDINALITY),
products AS (SELECT ordinality::int-1 idx,value v FROM jsonb_array_elements(PRODUCTS_JSON) WITH ORDINALITY),
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
"""
    sql=sql.replace('COMPANIES_JSON',literal(companies)).replace('PRODUCTS_JSON',literal(products))
    Path('supabase/pricechangerecord_seed.sql').write_text(sql,encoding='utf8')
    print(json.dumps(dict(rows=1200,companies=len(companies),products=len(products)),ensure_ascii=False))

if __name__=='__main__':build()
