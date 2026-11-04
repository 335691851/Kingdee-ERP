import sys,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sqlalchemy import text,select,func
from app.db import engine
from app import schema as s
from app.catalog import REGISTRY
def validate(minimum=10000):
    queries={
      'header_line_totals':'''SELECT count(*) FROM document d JOIN (SELECT document_id, SUM(net_cents) n, SUM(tax_cents) t, SUM(total_cents) a FROM document_line GROUP BY document_id) l ON d.id=l.document_id WHERE d.net_cents<>l.n OR d.tax_cents<>l.t OR d.total_cents<>l.a''',
      'voucher_balance':'''SELECT count(*) FROM (SELECT voucher_id FROM voucher_line GROUP BY voucher_id HAVING SUM(debit_cents)<>SUM(credit_cents)) x''',
      'stock_quantity_and_cost':'''SELECT count(*) FROM stock_balance b LEFT JOIN (SELECT company_id,warehouse_id,material_id,lot_id,SUM(qty_delta) q,SUM(cost_delta_cents) c FROM stock_transaction GROUP BY company_id,warehouse_id,material_id,lot_id) t ON b.company_id=t.company_id AND b.warehouse_id=t.warehouse_id AND b.material_id=t.material_id AND b.lot_id=t.lot_id WHERE ABS(b.qty-COALESCE(t.q,0))>0.00001 OR b.cost_cents<>COALESCE(t.c,0)''',
      'stock_company_lot_ownership':'''SELECT count(*) FROM stock_transaction t JOIN warehouse w ON t.warehouse_id=w.id JOIN lot l ON t.lot_id=l.id WHERE t.company_id<>w.company_id OR t.company_id<>l.company_id OR t.material_id<>l.material_id''',
      'settlement_legal_entity_partner':'''SELECT count(*) FROM settlement x JOIN document b ON x.bill_id=b.id JOIN document c ON x.cash_id=c.id WHERE b.company_id<>c.company_id OR b.partner_id<>c.partner_id OR x.company_id<>b.company_id''',
      'settlement_balance':'''SELECT count(*) FROM document d LEFT JOIN (SELECT id,SUM(a) a FROM (SELECT bill_id id,amount_cents a FROM settlement UNION ALL SELECT cash_id id,amount_cents a FROM settlement) z GROUP BY id) t ON d.id=t.id WHERE d.settled_cents<>COALESCE(t.a,0)''',
      'cost_pool_allocation':'''SELECT count(*) FROM cost_pool p LEFT JOIN (SELECT pool_id,SUM(allocated_cents) a FROM cost_allocation GROUP BY pool_id) x ON p.id=x.pool_id WHERE p.amount_cents<>COALESCE(x.a,0)''',
      'cost_rollup':'''SELECT count(*) FROM cost_calculation WHERE total_cents<>opening_wip_cents+material_cents+labor_cents+overhead_cents-closing_wip_cents''',
      'cost_component_allocation':'''SELECT count(*) FROM cost_calculation c JOIN (SELECT a.calculation_id,SUM(CASE WHEN p.item='labor' THEN a.allocated_cents ELSE 0 END) labor,SUM(CASE WHEN p.item='overhead' THEN a.allocated_cents ELSE 0 END) overhead FROM cost_allocation a JOIN cost_pool p ON p.id=a.pool_id GROUP BY a.calculation_id) x ON x.calculation_id=c.id WHERE x.labor<>c.labor_cents OR x.overhead<>c.overhead_cents''',
      'internal_trade_amount_match':'''SELECT count(*) FROM document_link l JOIN document a ON a.id=l.source_id JOIN document b ON b.id=l.target_id WHERE l.relation='intercompany' AND (a.total_cents<>b.total_cents OR a.company_id=b.company_id)''',
      'all_history_simulated':'''SELECT count(*) FROM document WHERE is_simulated=false''',
      'production_wip_cleared':'''SELECT count(*) FROM (SELECT v.company_id,SUM(l.debit_cents-l.credit_cents) b FROM voucher_line l JOIN voucher v ON v.id=l.voucher_id JOIN gl_account a ON a.id=l.account_id WHERE a.code='5001' GROUP BY v.company_id HAVING SUM(l.debit_cents-l.credit_cents)<>0) x'''
    }
    queries.update({
      'material_leaf_classification':'''SELECT count(*) FROM material m JOIN material_category c ON m.category_id=c.id LEFT JOIN material_category p ON c.parent_id=p.id WHERE c.level<>2 OR p.level<>1 OR (m.kind='product' AND p.id=3) OR (m.kind<>'product' AND p.id<>3)''',
      'food_small_pack_consistency':'''SELECT count(*) FROM material WHERE (category_id=12 AND packaging<>'small') OR (category_id IN (22,23) AND packaging<>'bulk') OR (category_id=23 AND salt_origin<>'sea')''',
      'bulk_has_no_packaging_bom':'''SELECT count(*) FROM bom b JOIN material m ON b.material_id=m.id JOIN bom_line bl ON bl.bom_id=b.id JOIN material component ON component.id=bl.component_id WHERE m.packaging='bulk' AND component.kind='packaging' ''',
      'production_material_actual_cost':'''SELECT count(*) FROM cost_calculation c JOIN (SELECT l.source_id production_id,SUM(dl.cost_cents) actual FROM document_link l JOIN document d ON d.id=l.target_id JOIN document_line dl ON dl.document_id=d.id WHERE d.type_code='material_issue' AND d.status IN ('posted','closed') GROUP BY l.source_id) a ON c.production_id=a.production_id WHERE c.material_cents<>a.actual''',
      'bom_issue_quantity_match':'''SELECT count(*) FROM production_detail p JOIN bom_line b ON p.bom_id=b.bom_id LEFT JOIN (SELECT l.source_id,dl.material_id,SUM(dl.qty) qty FROM document_link l JOIN document d ON l.target_id=d.id JOIN document_line dl ON dl.document_id=d.id WHERE d.type_code='material_issue' AND d.status IN ('posted','closed') GROUP BY l.source_id,dl.material_id) a ON a.source_id=p.document_id AND a.material_id=b.component_id WHERE ABS(p.completed_qty*b.qty_per_ton-COALESCE(a.qty,0))>0.00001''',
    })
    with engine.connect() as c:
        counts={r.type_code:r.n for r in c.execute(select(s.document.c.type_code,func.count().label('n')).group_by(s.document.c.type_code))}
        tables={t.name:c.execute(select(func.count()).select_from(t)).scalar() for t in s.M.sorted_tables}
        errors={k:c.execute(text(v)).scalar() for k,v in queries.items()}
        errors['minimum_history_per_document_type']=sum(counts.get(t,0)<minimum for t in REGISTRY)
        errors['minimum_cost_calculations']=int(tables['cost_calculation']<minimum)
        if engine.dialect.name=='sqlite':errors['foreign_key_errors']=len(c.exec_driver_sql('PRAGMA foreign_key_check').all())
        else:errors['foreign_key_errors']=c.execute(text("SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname='public' AND c.contype='f' AND NOT c.convalidated")).scalar()
        classes=[dict(r) for r in c.execute(text('''SELECT p.name level1,c.name level2,COUNT(m.id) material_count FROM material_category c JOIN material_category p ON c.parent_id=p.id LEFT JOIN material m ON m.category_id=c.id WHERE c.level=2 GROUP BY p.name,c.name ORDER BY p.name,c.name''')).mappings()]
        coverage=[dict(r) for r in c.execute(text('''SELECT c.id,c.name,COUNT(DISTINCT d.id) sales_documents FROM material_category c LEFT JOIN material m ON m.category_id=c.id LEFT JOIN document_line l ON l.material_id=m.id LEFT JOIN document d ON d.id=l.document_id AND d.type_code='sales_outbound' WHERE c.id IN (11,12,21,22,23,24,25) GROUP BY c.id,c.name ORDER BY c.id''')).mappings()]
        if minimum>=10000:errors['seven_photo_varieties_have_history']=sum(r['sales_documents']==0 for r in coverage)
    result=dict(simulated=True,minimum_per_type=minimum,document_counts=counts,table_counts=tables,classification=classes,variety_history=coverage,violations=errors,passed=all(v==0 for v in errors.values()))
    return result
if __name__=='__main__':
    result=validate();Path('outputs').mkdir(exist_ok=True);Path('outputs/data-validation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8');print(json.dumps(result,ensure_ascii=False,indent=2));sys.exit(0 if result['passed'] else 1)
