import os
from pathlib import Path
os.environ['DATABASE_URL']='sqlite:///./work/erp-tests.db'
os.environ['AUTH_MODE']='demo'
os.environ['SESSION_SECRET']='unit-tests-only-secret-not-for-production'
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select,func
from app.db import engine
from app import schema as s
from app.main import app
from scripts.seed import seed
HEAD={'X-ERP-Client':'luyan-web'}
@pytest.fixture(scope='module',autouse=True)
def setup():
    s.M.drop_all(engine);seed(8)
@pytest.fixture()
def client():
    c=TestClient(app);r=c.post('/api/auth/login',json={'username':'admin','password':'luyan-demo-2026'},headers=HEAD);assert r.status_code==200;return c
def make(c,typ='sales_order',cid=1,mid=1,qty='2',price='1050.00',wh=None):
    payload=dict(company_id=cid,type_code=typ,bill_date='2026-11-01',partner_id=None,warehouse_id=wh or (cid-1)*3+1,lines=[dict(material_id=mid,qty=qty,unit_price=price,tax_rate='.09')])
    r=c.post('/api/documents',json=payload,headers=HEAD);assert r.status_code==201,r.text;return r.json()['id']
def act(c,id,a):
    d=c.get('/api/documents/'+str(id)).json()['document'];return c.post(f'/api/documents/{id}/action',json=dict(action=a,version=d['version']),headers=HEAD)
def post(c,id):
    for action in ['submit','approve','post']:
        r=act(c,id,action);assert r.status_code==200,r.text
def test_auth_and_csrf():
    c=TestClient(app);assert c.get('/api/meta').status_code==401
    assert c.post('/api/auth/login',json={}).status_code==403
    assert c.post('/api/auth/login',json={'username':'admin','password':'wrong'},headers=HEAD).status_code==401
def test_read_all_modules(client):
    for url in ['/api/meta','/api/dashboard','/api/documents?type_code=sales_order','/api/inventory','/api/costing','/api/vouchers','/api/profit']:
        r=client.get(url);assert r.status_code==200,(url,r.text)
    d=client.get('/api/documents?type_code=sales_order&page_size=1').json();assert d['total']==16 and len(d['items'])==1
    assert client.get('/api/documents?page_size=1000').status_code==422
def test_price_state_version_and_lineage(client):
    id=make(client);d=client.get(f'/api/documents/{id}').json()['document'];assert d['total_cents']==210000 and d['net_cents']==192661
    assert act(client,id,'post').status_code==409
    assert act(client,id,'submit').status_code==200
    stale=client.post(f'/api/documents/{id}/action',json={'action':'approve','version':1},headers=HEAD);assert stale.status_code==409
    assert act(client,id,'approve').status_code==200
    r=client.post(f'/api/documents/{id}/downstream',headers=HEAD);assert r.status_code==200,r.text
    assert client.post(f'/api/documents/{id}/downstream',headers=HEAD).status_code==409
    detail=client.get('/api/documents/'+str(r.json()['id'])).json();assert detail['links'][0]['source_id']==id
def test_inventory_rollback(client):
    id=make(client,'sales_outbound',1,1,'999999','1000',2)
    assert act(client,id,'submit').status_code==200;assert act(client,id,'approve').status_code==200
    assert act(client,id,'post').status_code==409
    d=client.get(f'/api/documents/{id}').json();assert d['document']['status']=='approved'
    with engine.connect() as c:assert c.execute(select(func.count()).select_from(s.stock_transaction).join(s.document_line).where(s.document_line.c.document_id==id)).scalar()==0
def test_company_isolation_and_viewer(client):
    with engine.begin() as c:c.execute(s.membership.update().where(s.membership.c.user_id==1).values(role='viewer'))
    assert client.post('/api/documents',json=dict(company_id=1,type_code='sales_order',bill_date='2026-11-01',lines=[dict(material_id=1,qty=1,unit_price=1)]),headers=HEAD).status_code==403
    with engine.begin() as c:
        c.execute(s.membership.update().values(role='admin'))
        c.execute(s.membership.delete().where(s.membership.c.user_id==1,s.membership.c.company_id==2))
    assert client.get('/api/documents?company_id=2').status_code==403
    with engine.begin() as c:c.execute(s.membership.insert().values(user_id=1,company_id=2,role='admin'))
def test_over_settlement_and_cross_company(client):
    with engine.connect() as c:
        b=c.execute(select(s.document).where(s.document.c.type_code=='ar_bill')).mappings().first()
        cash=c.execute(select(s.document).where(s.document.c.type_code=='receipt',s.document.c.company_id!=b['company_id'])).mappings().first()
    r=client.post('/api/settlements',json={'bill_id':b['id'],'cash_id':cash['id'],'amount':'1'},headers=HEAD);assert r.status_code==422
def test_production_cost_end_to_end(client):
    # New raw/pack lots provide real inventory for a new production batch.
    a=make(client,'purchase_inbound',2,9,'10','226',4);post(client,a)
    b=make(client,'purchase_inbound',2,21,'1000','0.40',4);post(client,b)
    inner=make(client,'purchase_inbound',2,22,'20000','0.03',4);post(client,inner)
    prod=make(client,'production',2,1,'5','0',4);post(client,prod)
    r=client.post(f'/api/documents/{prod}/downstream',headers=HEAD);assert r.status_code==200,r.text
    issue=r.json()['id'];post(client,issue)
    r=client.post(f'/api/production/{prod}/report',json={'completed_qty':'5','labor_hours':'10','machine_hours':'8'},headers=HEAD);assert r.status_code==200,r.text
    for item,amount in [('labor','100'),('overhead','80')]:
        r=client.post('/api/costing/pools',json=dict(company_id=2,period='2026-11',item=item,amount=amount),headers=HEAD);assert r.status_code==201,r.text
    r=client.post('/api/costing/run',json=dict(company_id=2,period='2026-11'),headers=HEAD);assert r.status_code==200,r.text;assert r.json()['calculated']==1
    r=client.post(f'/api/production/{prod}/finish',headers=HEAD);assert r.status_code==201,r.text
    post(client,r.json()['id'])
    with engine.connect() as c:
        calc=c.execute(select(s.cost_calculation).where(s.cost_calculation.c.production_id==prod)).mappings().one()
        assert calc['labor_cents']==10000 and calc['overhead_cents']==8000 and calc['status']=='final'
        assert calc['total_cents']==calc['material_cents']+18000
    r=client.post('/api/costing/run',json=dict(company_id=2,period='2026-11'),headers=HEAD);assert r.json()['calculated']==0

def test_purchase_product_and_accrual_not_duplicated(client):
    inbound=make(client,'purchase_inbound',1,1,'1','109',2);post(client,inbound)
    current=inbound
    for target in ['ap_accrual','invoice_received','ap_bill']:
        r=client.post(f'/api/documents/{current}/downstream',headers=HEAD);assert r.status_code==200,r.text
        current=r.json()['id'];post(client,current)
    with engine.connect() as c:
        rows=c.execute(select(s.gl_account.c.code,func.sum(s.voucher_line.c.credit_cents).label('credit'),func.sum(s.voucher_line.c.debit_cents).label('debit')).select_from(s.voucher_line.join(s.gl_account).join(s.voucher,s.voucher_line.c.voucher_id==s.voucher.c.id)).where(s.voucher.c.document_id.in_([inbound,current])).group_by(s.gl_account.c.code)).mappings().all()
    amounts={r['code']:r for r in rows}
    assert amounts['1405']['debit']==10000
    assert amounts['2202']['credit']==10900
    assert amounts['222101']['debit']==900

def test_standalone_expense_bill_has_full_liability(client):
    bill=make(client,'ap_bill',1,1,'1','109');post(client,bill)
    with engine.connect() as c:
        amount=c.execute(select(func.sum(s.voucher_line.c.credit_cents)).select_from(s.voucher_line.join(s.voucher)).where(s.voucher.c.document_id==bill)).scalar()
    assert amount==10900

def test_two_level_taxonomy_and_independent_dimensions(client):
    meta=client.get('/api/meta').json();mats={m['id']:m for m in meta['materials']}
    assert len(mats)==27
    assert mats[7]['category']=='小包装' and mats[7]['product_feature']=='低钠盐'
    assert mats[4]['category_level1']=='非食用盐' and mats[4]['category']=='药用盐'
    assert mats[8]['classification_status']=='pending' and mats[8]['category']=='品种待确认'
    assert mats[5]['salt_origin']=='unknown'  # seaweed flavor does not establish sea salt origin
    assert mats[14]['salt_origin']=='sea' and mats[14]['packaging']=='bulk'
    assert {c['name'] for c in meta['categories'] if c['parent_id']==1}=={'食品加工用盐','小包装'}
    with engine.connect() as c:
        components={r.component_id:float(r.qty_per_ton) for r in c.execute(select(s.bom_line).join(s.bom).where(s.bom.c.company_id==2,s.bom.c.material_id==4))}
        assert components=={9:1.03,16:40.0}
        bulk=list(c.execute(select(s.material.c.kind).select_from(s.bom_line.join(s.bom).join(s.material,s.bom_line.c.component_id==s.material.c.id)).where(s.bom.c.material_id==14)))
        assert all(r.kind=='raw' for r in bulk)

def test_profit_classification_filters_and_rollup(client):
    all_rows=client.get('/api/profit').json();food=client.get('/api/profit?level1=1&level2=12').json()
    assert food['items'] and all(r['category_level1']=='食用盐' and r['category']=='小包装' for r in food['items'])
    for field in ['revenue_cents','cost_cents','profit_cents']:
        assert sum(r[field] for r in all_rows['items'])==sum(r[field] for r in all_rows['category_summary'])
    assert client.get('/api/profit?salt_origin=mineral').json()['items']==[]
