-- P0 ERP-side integration sources. Additive; no grants to public clients.
BEGIN;
CREATE TABLE public.ai_integration_scenario (
 scenario_id text PRIMARY KEY, run_date date NOT NULL, company_id integer NOT NULL REFERENCES company,
 material_id integer REFERENCES material, source_material_id integer REFERENCES material,
 lot_id integer REFERENCES lot, expected jsonb NOT NULL, source_refs text NOT NULL,
 is_simulated boolean NOT NULL DEFAULT true CHECK(is_simulated)
);
CREATE TABLE public.ai_restock_source (
 scenario_id text PRIMARY KEY REFERENCES ai_integration_scenario,
 company_id integer NOT NULL REFERENCES company, material_id integer NOT NULL REFERENCES material,
 plan_start date NOT NULL, plan_end date NOT NULL, snapshot_date date NOT NULL,
 order_line_id integer REFERENCES document_line, reserved_for_demand numeric NOT NULL CHECK(reserved_for_demand>=0),
 transit_ref text NOT NULL, transit_qty numeric NOT NULL CHECK(transit_qty>=0), transit_due date NOT NULL,
 scheduled_ref text NOT NULL, scheduled_qty numeric NOT NULL CHECK(scheduled_qty>=0), scheduled_due date NOT NULL,
 safety_qty numeric NOT NULL CHECK(safety_qty>=0), safety_approval text NOT NULL,
 capacity_ref text NOT NULL, total_capacity numeric NOT NULL, occupied_capacity numeric NOT NULL,
 source_refs text NOT NULL CHECK(length(source_refs)>20),
 CHECK(plan_start<=plan_end),CHECK(total_capacity>=occupied_capacity AND occupied_capacity>=0),
 UNIQUE(company_id,material_id,snapshot_date)
);
ALTER TABLE ai_integration_scenario ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_restock_source ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ai_integration_scenario,ai_restock_source FROM anon,authenticated;
CREATE VIEW public.ai_restock_plan_input WITH (security_invoker=true) AS
SELECT r.company_id,r.material_id,r.plan_start,r.plan_end,
 greatest(coalesce(ds.qty-ds.fulfilled_qty,0)-r.reserved_for_demand,0)::numeric demand_qty,
 coalesce(b.available,0)::numeric available_qty,
 CASE WHEN transit_due<=plan_end THEN transit_qty ELSE 0 END::numeric in_transit_qty,
 CASE WHEN scheduled_due<=plan_end THEN r.scheduled_qty ELSE 0 END::numeric scheduled_qty,
 r.safety_qty,(total_capacity-occupied_capacity)::numeric capacity_qty,r.snapshot_date,
 r.source_refs||';订单行='||coalesce(r.order_line_id::text,'无销售需求')||';在途='||transit_ref||';排产='||scheduled_ref||';安全批准='||safety_approval||';产能='||capacity_ref||';口径v1' source_refs
FROM ai_restock_source r JOIN company c ON c.id=r.company_id AND c.kind='生产法人'
JOIN material m ON m.id=r.material_id AND m.kind='product' JOIN uom u ON u.id=m.uom_id AND u.name='吨'
LEFT JOIN document_line dl ON dl.id=r.order_line_id LEFT JOIN document d ON d.id=dl.document_id
LEFT JOIN delivery_schedule ds ON ds.line_id=dl.id
LEFT JOIN LATERAL (SELECT sum(qty-reserved_qty) available FROM stock_balance b WHERE b.company_id=r.company_id AND b.material_id=r.material_id) b ON true
WHERE (r.order_line_id IS NULL OR (d.company_id=r.company_id AND dl.material_id=r.material_id AND d.type_code='sales_order' AND d.status IN('approved','posted','closed') AND ds.due_date::date BETWEEN r.plan_start AND r.plan_end))
AND EXISTS(SELECT 1 FROM bom WHERE company_id=r.company_id AND material_id=r.material_id);
REVOKE ALL ON ai_restock_plan_input FROM anon,authenticated;
COMMIT;
