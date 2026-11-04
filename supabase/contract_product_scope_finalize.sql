-- Label preserved originals only after every revised PDF is registered.
BEGIN;
DO $$ BEGIN
 IF (SELECT count(*) FROM sales_contract c WHERE c.contract_no LIKE 'SIM-HT-20261104-%' AND c.notes LIKE '批次：contract_sim_20261104_v1%' AND EXISTS(SELECT 1 FROM contract_attachment a WHERE a.contract_id=c.id AND a.filename=c.contract_no||'-产品范围版.pdf'))<>1000 THEN
  RAISE EXCEPTION 'Expected 1000 complete product-scope PDFs; original filenames unchanged';
 END IF;
END $$;
UPDATE contract_attachment a SET filename='历史旧版-'||a.filename
FROM sales_contract c WHERE c.id=a.contract_id AND c.contract_no LIKE 'SIM-HT-20261104-%' AND c.notes LIKE '批次：contract_sim_20261104_v1%' AND a.filename=c.contract_no||'.pdf';
COMMIT;
