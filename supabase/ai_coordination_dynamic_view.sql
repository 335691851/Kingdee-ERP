BEGIN;
CREATE OR REPLACE VIEW public.ai_restock_plan_input WITH (security_invoker=true) AS
SELECT r.company_id,r.material_id,r.plan_start,r.plan_end,
 greatest(coalesce(ds.qty-ds.fulfilled_qty,0)-r.reserved_for_demand,0)::numeric demand_qty,
 coalesce(b.available,0)::numeric available_qty,
 coalesce(tr.qty,0)::numeric in_transit_qty,
 coalesce(mo.qty,0)::numeric scheduled_qty,
 r.safety_qty,(total_capacity-occupied_capacity)::numeric capacity_qty,r.snapshot_date,
 r.source_refs||';来源记录=ai_restock_source/'||r.scenario_id||';订单行='||coalesce(r.order_line_id::text,'无销售需求')||';在途='||transit_ref||';排产='||scheduled_ref||';安全批准='||safety_approval||';产能='||capacity_ref||';口径v1' source_refs
FROM ai_restock_source r JOIN company c ON c.id=r.company_id AND c.kind='生产法人'
JOIN material m ON m.id=r.material_id AND m.kind='product' JOIN uom u ON u.id=m.uom_id AND u.name='吨'
LEFT JOIN document_line dl ON dl.id=r.order_line_id LEFT JOIN document d ON d.id=dl.document_id
LEFT JOIN delivery_schedule ds ON ds.line_id=dl.id
LEFT JOIN LATERAL (SELECT sum(qty-reserved_qty) available FROM stock_balance b WHERE b.company_id=r.company_id AND b.material_id=r.material_id) b ON true
LEFT JOIN LATERAL (SELECT sum(greatest(ds.qty-ds.fulfilled_qty,0)) qty FROM document t JOIN document_line tl ON tl.document_id=t.id JOIN delivery_schedule ds ON ds.line_id=tl.id WHERE t.bill_no=r.transit_ref AND t.company_id=r.company_id AND tl.material_id=r.material_id AND t.status IN('approved','posted') AND ds.due_date::date BETWEEN r.plan_start AND r.plan_end) tr ON true
LEFT JOIN LATERAL (SELECT sum(greatest(pd.planned_qty-pd.completed_qty,0)) qty FROM document t JOIN production_detail pd ON pd.document_id=t.id JOIN document_line tl ON tl.document_id=t.id WHERE t.bill_no=r.scheduled_ref AND t.company_id=r.company_id AND tl.material_id=r.material_id AND t.status IN('approved','posted') AND pd.end_date::date BETWEEN r.plan_start AND r.plan_end) mo ON true
WHERE (r.order_line_id IS NULL OR (d.company_id=r.company_id AND dl.material_id=r.material_id AND d.type_code='sales_order' AND d.status IN('approved','posted','closed') AND ds.due_date::date BETWEEN r.plan_start AND r.plan_end))
AND EXISTS(SELECT 1 FROM bom WHERE company_id=r.company_id AND material_id=r.material_id);

COMMIT;
