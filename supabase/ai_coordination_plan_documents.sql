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
DECLARE r record; wh int; did int; ln int; bid int;
BEGIN
 FOR r IN SELECT * FROM ai_restock_source LOOP
 SELECT id INTO wh FROM warehouse WHERE company_id=r.company_id AND kind='产成品库' ORDER BY id LIMIT 1;
 IF r.transit_qty>0 AND NOT EXISTS(SELECT 1 FROM document WHERE bill_no='SIM-AIP-'||r.scenario_id||'-TR') THEN
 did=pg_temp.aip_doc(r.company_id,r.material_id,wh,NULL,r.scenario_id,'TR','purchase_order',r.snapshot_date,r.transit_qty,'approved');
 INSERT INTO delivery_schedule(line_id,due_date,qty,fulfilled_qty) SELECT id,r.transit_due::text,qty,0 FROM document_line WHERE document_id=did;
 END IF;
 IF r.scheduled_qty>0 AND NOT EXISTS(SELECT 1 FROM document WHERE bill_no='SIM-AIP-'||r.scenario_id||'-MO') THEN
 did=pg_temp.aip_doc(r.company_id,r.material_id,wh,NULL,r.scenario_id,'MO','production',r.snapshot_date,r.scheduled_qty,'approved');
 SELECT id INTO bid FROM bom WHERE company_id=r.company_id AND material_id=r.material_id ORDER BY id LIMIT 1;
 INSERT INTO production_detail(document_id,bom_id,planned_qty,completed_qty,work_center,start_date,end_date) VALUES(did,bid,r.scheduled_qty,0,'SIM-AIP-模拟生产单元',r.plan_start::text,r.scheduled_due::text);
 END IF;
 END LOOP;
END $$;
COMMIT;
