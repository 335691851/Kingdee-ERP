WITH facts AS (
SELECT s.*,m.code material_code,
b.p,b.r,t.first_in,t.flow_qty,
q.q,q.documents,
v.demand_qty,v.safety_qty,v.available_qty,v.in_transit_qty,v.scheduled_qty,v.capacity_qty,v.snapshot_date,v.plan_start,v.plan_end,v.source_refs plan_sources,
greatest(v.demand_qty+v.safety_qty-v.available_qty-v.in_transit_qty-v.scheduled_qty,0) gap
FROM ai_integration_scenario s JOIN material m ON m.id=s.material_id
LEFT JOIN LATERAL(SELECT sum(qty) p,sum(reserved_qty) r FROM stock_balance WHERE company_id=s.company_id AND material_id=s.material_id AND lot_id=s.lot_id) b ON true
LEFT JOIN LATERAL(SELECT min(posted_on::date) FILTER(WHERE qty_delta>0) first_in,sum(qty_delta) flow_qty FROM stock_transaction WHERE company_id=s.company_id AND material_id=s.material_id AND lot_id=s.lot_id) t ON true
LEFT JOIN LATERAL(SELECT coalesce(sum(l.qty) FILTER(WHERE d.type_code='sales_order' AND d.status IN('approved','posted','closed') AND d.bill_date::date>=s.run_date-30 AND d.bill_date::date<s.run_date),0) q,jsonb_agg(jsonb_build_object('id',d.id,'bill_no',d.bill_no,'date',d.bill_date,'status',d.status,'line_id',l.id,'line_no',l.line_no,'qty',l.qty,'is_simulated',d.is_simulated) ORDER BY d.id) documents FROM document d JOIN document_line l ON l.document_id=d.id WHERE d.company_id=s.company_id AND l.material_id=s.material_id) q ON true
LEFT JOIN ai_restock_plan_input v ON v.company_id=s.company_id AND v.material_id=s.material_id
WHERE NOT (s.expected ? 'rejected')
), result AS (
SELECT *,CASE left(scenario_id,1)
 WHEN 'T' THEN p>0 AND p<.5 AND first_in<(run_date-interval '3 months')::date
 WHEN 'C' THEN p-r>0 AND (q<=0 OR p-r>2*q)
 WHEN 'R' THEN gap>0 AND snapshot_date BETWEEN run_date-1 AND run_date END actual_hit,
CASE WHEN q>0 THEN (p-r)/q*30 END coverage_days,
least(gap,capacity_qty) suggested_qty,greatest(gap-capacity_qty,0) coordination_qty,
(SELECT jsonb_agg(jsonb_build_object('warehouse_id',warehouse_id,'qty',qty,'reserved_qty',reserved_qty)) FROM stock_balance b WHERE b.company_id=facts.company_id AND b.material_id=facts.material_id) warehouses
FROM facts)
SELECT jsonb_agg(to_jsonb(result)||jsonb_build_object('passed',actual_hit=(expected->>'hit')::boolean AND p=flow_qty) ORDER BY scenario_id) scenarios FROM result;
