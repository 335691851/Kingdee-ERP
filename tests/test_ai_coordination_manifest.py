import json
from pathlib import Path
from decimal import Decimal

ROWS=json.loads((Path(__file__).parents[1]/'outputs/ai-coordination-scenarios.json').read_text(encoding='utf8'))

def test_export_is_complete_and_independent():
 assert len(ROWS)==31
 assert len({(r['company_id'],r['material_id']) for r in ROWS})==31
 for r in ROWS:
  assert r['passed'] and r['is_simulated']
  assert Decimal(str(r['p']))==Decimal(str(r['flow_qty']))
  assert all(d['is_simulated'] and d['bill_no'].startswith('SIM-AIP-') and d['line_id'] for d in r['documents'])

def test_contract_matrix_results():
 for prefix in ('T','C','R'):
  hits={r['scenario_id'] for r in ROWS if r['scenario_id'].startswith(prefix) and r['actual_hit'] and int(r['scenario_id'][1:])<=9}
  assert hits=={prefix+str(n).zfill(2) for n in range(1,7)}
 by={r['scenario_id']:r for r in ROWS}
 assert (by['R02']['gap'],by['R02']['suggested_qty'],by['R02']['coordination_qty'])==(50,40,10)
 assert (by['R06']['demand_qty'],by['R06']['available_qty'],by['R06']['gap'])==(40,20,20)
 assert len(by['T06']['warehouses'])==2 and by['T06']['p']==.4
 assert by['C07']['coverage_days']==60 and not by['C07']['actual_hit']
