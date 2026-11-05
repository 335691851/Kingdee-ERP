-- Controlled ERP import: mirrors inventory valuation and voucher rules in services.py.
-- No lasting privileged function is installed. One atomic batch, repeat execution is a no-op.
BEGIN;
SELECT pg_advisory_xact_lock(781105);
CREATE FUNCTION pg_temp.aip_doc(cid int,mid int,wh int,lid int,sc text,suffix text,typ text,dt date,q numeric,st text DEFAULT 'posted') RETURNS int LANGUAGE plpgsql AS $$
DECLARE did int; ln int; vid int; cost bigint; net bigint; tax bigint; a int; z int;
BEGIN
 IF q<=0 THEN RAISE EXCEPTION 'Positive quantity required'; END IF;
 IF EXISTS(SELECT 1 FROM fiscal_period WHERE company_id=cid AND period=to_char(dt,'YYYY-MM') AND closed) THEN RAISE EXCEPTION 'Closed fiscal period'; END IF;
 IF NOT EXISTS(SELECT 1 FROM material_org WHERE company_id=cid AND material_id=mid) OR NOT EXISTS(SELECT 1 FROM warehouse WHERE id=wh AND company_id=cid) THEN RAISE EXCEPTION 'Ownership mismatch'; END IF;
 cost=round(q*50000);net=round(q*80000);tax=round(net*.09);
 INSERT INTO document(company_id,type_code,bill_no,bill_date,status,warehouse_id,currency_id,net_cents,tax_cents,total_cents,settled_cents,freight_cents,version,is_simulated,memo,created_at,updated_at)
 VALUES(cid,typ,'SIM-AIP-'||sc||'-'||suffix,dt::text,st,wh,(SELECT id FROM currency WHERE code='CNY'),net,tax,net+tax,0,0,4,true,'联调模拟＋'||sc||'；独立模拟SKU；非企业真实交易',now()::text,now()::text) RETURNING id INTO did;
 INSERT INTO document_line(document_id,line_no,material_id,qty,unit_price_cents,tax_rate,net_cents,tax_cents,total_cents,cost_cents,lot_id)
 VALUES(did,1,mid,q,80000,.09,net,tax,net+tax,CASE WHEN typ='sales_order' THEN cost ELSE 0 END,lid) RETURNING id INTO ln;
 IF typ IN('purchase_inbound','sales_outbound') THEN
  IF typ='purchase_inbound' THEN cost=net;
   INSERT INTO stock_balance(company_id,warehouse_id,material_id,lot_id,qty,reserved_qty,cost_cents,version) VALUES(cid,wh,mid,lid,q,0,cost,1)
   ON CONFLICT(company_id,warehouse_id,material_id,lot_id) DO UPDATE SET qty=stock_balance.qty+q,cost_cents=stock_balance.cost_cents+cost,version=stock_balance.version+1;
   a=(SELECT id FROM gl_account WHERE code='1405');z=(SELECT id FROM gl_account WHERE code='2202');
  ELSE
   SELECT round(b.cost_cents*q/b.qty) INTO cost FROM stock_balance b WHERE company_id=cid AND warehouse_id=wh AND material_id=mid AND lot_id=lid AND qty-reserved_qty>=q FOR UPDATE;
   IF cost IS NULL THEN RAISE EXCEPTION 'Insufficient free inventory'; END IF;
   UPDATE stock_balance SET qty=qty-q,cost_cents=cost_cents-cost,version=version+1 WHERE company_id=cid AND warehouse_id=wh AND material_id=mid AND lot_id=lid;
   a=(SELECT id FROM gl_account WHERE code='6401');z=(SELECT id FROM gl_account WHERE code='1405');
  END IF;
  UPDATE document_line SET cost_cents=cost WHERE id=ln;
  INSERT INTO stock_transaction(company_id,line_id,warehouse_id,material_id,lot_id,posted_on,qty_delta,cost_delta_cents,posting_key)
  VALUES(cid,ln,wh,mid,lid,dt::text,CASE WHEN typ='purchase_inbound' THEN q ELSE -q END,CASE WHEN typ='purchase_inbound' THEN cost ELSE -cost END,'line:'||ln);
  INSERT INTO voucher(company_id,document_id,voucher_no,posted_on,period,status,posting_key) VALUES(cid,did,'JZ-SIM-AIP-'||sc||'-'||suffix,dt::text,to_char(dt,'YYYY-MM'),'posted','doc:'||did) RETURNING id INTO vid;
  INSERT INTO voucher_line(voucher_id,account_id,debit_cents,credit_cents) VALUES(vid,a,cost,0),(vid,z,0,cost);
 END IF;
 INSERT INTO audit_event(company_id,document_id,actor,action,before_state,after_state,created_at)
 VALUES(cid,did,'ERP联调导入','integration_import','{}',jsonb_build_object('scenario',sc,'status',st,'is_simulated',true)::text,now()::text);
 RETURN did;
END $$;
CREATE FUNCTION pg_temp.aip_stock(cid int,mid int,lid int,sc text,dt date,final_qty numeric,res numeric,multi boolean DEFAULT false) RETURNS void LANGUAGE plpgsql AS $$
DECLARE wh int; wh2 int; did int;
BEGIN
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 IF multi THEN
  INSERT INTO warehouse(company_id,name,kind) VALUES(cid,'SIM-AIP-联调成品第二库','产成品库') RETURNING id INTO wh2;
  PERFORM pg_temp.aip_doc(cid,mid,wh,lid,sc,'IN-1','purchase_inbound',dt,6);
  PERFORM pg_temp.aip_doc(cid,mid,wh2,lid,sc,'IN-2','purchase_inbound',dt,4);
  PERFORM pg_temp.aip_doc(cid,mid,wh,lid,sc,'OUT-1','sales_outbound',((now() AT TIME ZONE 'Asia/Shanghai')::date)-1,6-final_qty/2);
  PERFORM pg_temp.aip_doc(cid,mid,wh2,lid,sc,'OUT-2','sales_outbound',((now() AT TIME ZONE 'Asia/Shanghai')::date)-1,4-final_qty/2);
 ELSE
  PERFORM pg_temp.aip_doc(cid,mid,wh,lid,sc,'IN','purchase_inbound',dt,greatest(10,final_qty+10));
  IF true THEN did=pg_temp.aip_doc(cid,mid,wh,lid,sc,'OUT','sales_outbound',((now() AT TIME ZONE 'Asia/Shanghai')::date)-1,greatest(10,final_qty+10)-final_qty); END IF;
 END IF;
 UPDATE stock_balance SET reserved_qty=CASE WHEN warehouse_id=wh THEN res ELSE 0 END WHERE company_id=cid AND material_id=mid AND lot_id=lid;
END $$;
DO $$
DECLARE d date=(now() AT TIME ZONE 'Asia/Shanghai')::date; cutoff date; mid int; lid int; wh int; bid int; ln int; docid int; sc text; x jsonb; src int; cid int;
BEGIN
 IF EXISTS(SELECT 1 FROM ai_integration_scenario) THEN RETURN; END IF;
 cutoff=(d-interval '3 months')::date;

 x='{"id": "T01", "cid": 5, "p": 0.32, "r": 0, "age": 30, "multi": false, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T02", "cid": 4, "p": 0.18, "r": 0.08, "age": 1, "multi": false, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T03", "cid": 7, "p": 0.46, "r": 0.1, "age": 45, "multi": false, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T04", "cid": 8, "p": 0.09, "r": 0, "age": 15, "multi": false, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T05", "cid": 2, "p": 0.25, "r": 0.25, "age": 60, "multi": false, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T06", "cid": 7, "p": 0.4, "r": 0.05, "age": 10, "multi": true, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T07", "cid": 5, "p": 0.32, "r": 0, "age": 0, "multi": false, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T08", "cid": 4, "p": 0.5, "r": 0, "age": 1, "multi": false, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T09", "cid": 7, "p": 0, "r": 0, "age": 1, "multi": false, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "T10", "cid": 8, "p": 0.6, "r": 0, "age": 1, "multi": true, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "C01", "cid": 7, "p": 120, "r": 20, "q": 30, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C02", "cid": 8, "p": 80, "r": 0, "q": 0, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "C03", "cid": 6, "p": 55, "r": 5, "q": 20, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C04", "cid": 5, "p": 500, "r": 100, "q": 100, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C05", "cid": 4, "p": 150, "r": 0, "q": 50, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C06", "cid": 12, "p": 12, "r": 2, "q": 1, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C07", "cid": 7, "p": 120, "r": 20, "q": 50, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C08", "cid": 8, "p": 35, "r": 5, "q": 20, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C09", "cid": 6, "p": 20, "r": 20, "q": 0, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;

 x='{"id": "R01", "cid": 5, "p": 20, "r": 0, "q": 100, "s": 10, "t": 15, "m": 25, "cap": 80, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R02", "cid": 4, "p": 20, "r": 0, "q": 100, "s": 10, "t": 15, "m": 25, "cap": 40, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R03", "cid": 5, "p": 10, "r": 0, "q": 60, "s": 0, "t": 0, "m": 0, "cap": 0, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R04", "cid": 4, "p": 5, "r": 0, "q": 0, "s": 20, "t": 0, "m": 0, "cap": 30, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 ln=NULL;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R05", "cid": 5, "p": 10, "r": 0, "q": 80, "s": 5, "t": 20, "m": 10, "cap": 60, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R06", "cid": 4, "p": 80, "r": 60, "q": 40, "s": 0, "t": 0, "m": 0, "cap": 50, "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R07", "cid": 5, "p": 30, "r": 0, "q": 20, "s": 5, "t": 0, "m": 0, "cap": 50, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "R08", "cid": 4, "p": 20, "r": 0, "q": 100, "s": 10, "t": 15, "m": 25, "cap": 80, "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 INSERT INTO bom(company_id,material_id,version,yield_rate) SELECT cid,mid,'SIM-AIP-v1',yield_rate FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1 RETURNING id INTO bid;
 IF bid IS NULL THEN RAISE EXCEPTION 'Missing factory source BOM'; END IF;
 INSERT INTO bom_line(bom_id,component_id,qty_per_ton) SELECT bid,component_id,qty_per_ton FROM bom_line WHERE bom_id=(SELECT id FROM bom WHERE company_id=cid AND material_id=src ORDER BY id LIMIT 1);
 IF ln IS NOT NULL THEN INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT ln,(d+14)::text,qty,0 FROM document_line WHERE id=ln; END IF;
 INSERT INTO ai_restock_source VALUES(sc,cid,mid,d,d+14,CASE WHEN sc='R08' THEN d-2 ELSE d END,ln,CASE WHEN sc='R06' THEN 60 ELSE 0 END,'SIM-AIP-'||sc||'-TR',(x->>'t')::numeric,d+7,'SIM-AIP-'||sc||'-MO',(x->>'m')::numeric,d+10,(x->>'s')::numeric,'SIM-AIP-'||sc||'-SAFE-模拟批准','SIM-AIP-'||sc||'-CAP-模拟能力',(x->>'cap')::numeric+(x->>'m')::numeric,(x->>'m')::numeric,'联调模拟＋'||sc||';供货工厂='||cid||';原型物料='||src||';预留与净需求去重;v1');

 x='{"id": "C10", "cid": 7, "p": 100, "r": 0, "q": 50, "offset": 0, "st": "approved", "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C11", "cid": 7, "p": 100, "r": 0, "q": 50, "offset": 30, "st": "approved", "hit": false}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=2;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C12", "cid": 7, "p": 100, "r": 0, "q": 50, "offset": 31, "st": "approved", "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=3;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;

 x='{"id": "C13", "cid": 7, "p": 100, "r": 0, "q": 50, "offset": 1, "st": "draft", "hit": true}'::jsonb; sc=x->>'id'; cid=(x->>'cid')::int; src=1;
 INSERT INTO material(code,name,spec,category_id,uom_id,kind,list_price_cents,lot_managed,salt_origin,packaging,product_feature,classification_status,source_note)
 SELECT 'SIM-AIP-'||sc,'联调模拟＋'||sc||'＋'||name,spec,category_id,uom_id,kind,list_price_cents,true,salt_origin,packaging,product_feature,classification_status,'联调模拟；独立SKU；原型物料ID='||src FROM material WHERE id=src RETURNING id INTO mid;
 INSERT INTO material_org(material_id,company_id) VALUES(mid,cid);
 SELECT id INTO wh FROM warehouse WHERE company_id=cid AND kind='产成品库' ORDER BY id LIMIT 1;
 INSERT INTO lot(company_id,material_id,lot_no,manufactured_on,expires_on) VALUES(cid,mid,'SIM-AIP-'||sc, (cutoff-90)::text,(d+365)::text) RETURNING id INTO lid;
 INSERT INTO ai_integration_scenario(scenario_id,run_date,company_id,material_id,source_material_id,lot_id,expected,source_refs)
 VALUES(sc,d,cid,mid,src,lid,x,'联调模拟＋'||sc||';单据前缀SIM-AIP-'||sc||';吨制;v1');
 PERFORM pg_temp.aip_stock(cid,mid,lid,sc,CASE WHEN left(sc,1)='T' THEN cutoff-(x->>'age')::int ELSE d-5 END,(x->>'p')::numeric,(x->>'r')::numeric,coalesce((x->>'multi')::boolean,false));
 docid=pg_temp.aip_doc(cid,mid,wh,NULL,sc,'SO','sales_order',d-coalesce((x->>'offset')::int,1),(x->>'q')::numeric+CASE WHEN sc='R06' THEN 60 ELSE 0 END,coalesce(x->>'st','approved'));
 SELECT id INTO ln FROM document_line WHERE document_id=docid;
 END $$;
COMMIT;
