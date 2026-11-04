"""Isolated form -> database -> attachment -> review integration tests."""
from copy import deepcopy
import pytest
import httpx
from sqlalchemy import create_engine,select,func
from sqlalchemy.pool import StaticPool
from fastapi.testclient import TestClient
from app import schema as s,contracts,contract_storage as storage
from app.main import app
from app.auth import current_user

HEAD={'X-ERP-Client':'luyan-web'}
PDF=b'%PDF-1.4\ncontract test\n%%EOF'
PAYLOAD=dict(company_id=1,organization_id=1,salesperson_id=1,contract_no='HT-2026-001',title='客户商品价格与服务协议',kind='mixed',
    signed_on='2026-11-04',valid_from='2026-11-01',valid_to='2027-10-31',customer_ids=[1],
    payment_terms='30 天后收款',service_terms='按月交货，提供售后服务',notes='',
    prices=[dict(material_id=1,unit_price='1050.25',min_qty='0',max_qty='100',includes_tax=True,tax_rate='.09')])

@pytest.fixture
def env(tmp_path,monkeypatch):
    db=create_engine('sqlite://',connect_args={'check_same_thread':False},poolclass=StaticPool)
    s.M.create_all(db)
    with db.begin() as c:
        for i in (1,2):
            c.execute(s.company.insert().values(id=i,code=str(i),name=f'法人{i}',kind='营销法人',legal_name_confirmed=True))
            c.execute(s.organization.insert().values(id=i,company_id=i,name=f'组织{i}',function='销售'))
            c.execute(s.department.insert().values(id=i,company_id=i,name='营销部'))
            c.execute(s.employee.insert().values(id=i,company_id=i,department_id=i,name=f'销售员{i}'))
            c.execute(s.app_user.insert().values(id=i,subject=str(i),name=f'账户{i}',enabled=True))
        c.execute(s.uom.insert().values(id=1,name='吨'))
        c.execute(s.material_category.insert().values(id=1,name='食用盐',code='FOOD',level=1))
        c.execute(s.material.insert().values(id=1,code='09020101106',name='鲁晶精制盐',spec='400g-20kg',category_id=1,uom_id=1,kind='product',list_price_cents=105000,lot_managed=True,salt_origin='unknown',packaging='small',product_feature='',classification_status='classified',source_note='测试'))
        c.execute(s.material_org.insert().values(material_id=1,company_id=1))
        for i in (1,2):
            c.execute(s.partner.insert().values(id=i,code=f'KH{i}',name=f'客户{i}',kind='customer'))
            c.execute(s.partner_role.insert().values(partner_id=i,company_id=i,role='customer'))
    actor={'id':1,'name':'账户1','grants':{1:'operator'}}
    app.dependency_overrides[current_user]=lambda:actor
    monkeypatch.setattr(contracts,'engine',db)
    monkeypatch.setattr(storage,'PRODUCTION',False)
    monkeypatch.setenv('CONTRACT_STORAGE_BACKEND','local')
    monkeypatch.setenv('CONTRACT_LOCAL_DIR',str(tmp_path/'private-files'))
    with TestClient(app) as client:yield client,actor,db
    app.dependency_overrides.clear();db.dispose()

def new(client,p=None):
    r=client.post('/api/contracts',json=p or deepcopy(PAYLOAD),headers=HEAD)
    assert r.status_code==201,r.text
    return r.json()['id']

def attach(client,id,version=1,filename='签章合同.pdf',body=PDF):
    return client.post(f'/api/contracts/{id}/attachments',params={'filename':filename,'version':version},content=body,headers=HEAD)

def act(client,id,a,v,note=''):
    return client.post(f'/api/contracts/{id}/action',json={'action':a,'version':v,'note':note},headers=HEAD)

def test_form_attachment_and_review_lifecycle(env):
    c,actor,db=env
    options=c.get('/api/contracts/options?company_id=1').json()
    assert [x['id'] for x in options['customers']]==[1] and options['materials'][0]['unit']=='吨'
    id=new(c)
    assert c.get('/api/contracts?q=客户1').json()['total']==1
    d=c.get(f'/api/contracts/{id}').json()
    assert d['prices'][0]['unit_price_cents']==105025 and d['customer_ids']==[1]
    assert act(c,id,'submit',1).status_code==422
    f=attach(c,id);assert f.status_code==201,f.text
    fid=f.json()['id']
    d=c.get(f'/api/contracts/{id}').json()
    assert 'object_key' not in d['attachments'][0] and d['contract']['version']==2
    r=c.get(f'/api/contracts/{id}/attachments/{fid}/download');assert r.content==PDF
    assert act(c,id,'submit',2).status_code==200
    assert attach(c,id,3).status_code==409
    assert act(c,id,'approve',3).status_code==403
    actor['grants'][1]='admin'
    assert act(c,id,'reject',3).status_code==422
    assert act(c,id,'reject',3,'请补充交货范围').status_code==200
    p=deepcopy(PAYLOAD);p['version']=4;p['service_terms']='修订交货范围'
    assert c.put(f'/api/contracts/{id}',json=p,headers=HEAD).status_code==200
    assert act(c,id,'submit',5).status_code==200
    assert act(c,id,'approve',6).status_code==200
    assert act(c,id,'terminate',7,'合同提前终止').status_code==200
    d=c.get(f'/api/contracts/{id}').json();assert len(d['events'])==8 and d['contract']['status']=='terminated'

def test_scope_owner_viewer_and_concurrency(env):
    c,actor,db=env;id=new(c)
    assert c.get('/api/contracts?company_id=2').status_code==403
    assert c.get('/api/contracts/options?company_id=2').status_code==403
    actor['grants']={2:'operator'}
    assert c.get(f'/api/contracts/{id}').status_code==403
    assert c.get('/api/contracts').json()['total']==0
    assert attach(c,id).status_code==403
    actor['grants']={1:'viewer'}
    assert c.get(f'/api/contracts/{id}').status_code==200
    assert act(c,id,'submit',1).status_code==403
    actor['grants']={1:'operator'};actor['id']=2
    assert attach(c,id).status_code==403
    actor['id']=1
    p=deepcopy(PAYLOAD);p['version']=1
    assert c.put(f'/api/contracts/{id}',json=p,headers=HEAD).status_code==200
    assert attach(c,id,1).status_code==409
    assert c.put(f'/api/contracts/{id}',json=p,headers=HEAD).status_code==409
    assert c.post('/api/contracts',json=PAYLOAD,headers=HEAD).status_code==409

@pytest.mark.parametrize('change',[
    {'organization_id':2},{'salesperson_id':2},{'customer_ids':[2]},
    {'customer_ids':[1,1]},{'valid_to':'2026-01-01'},{'prices':[]},{'service_terms':''},
    {'prices':[dict(material_id=999,unit_price='12.00')]},
    {'prices':[dict(material_id=1,unit_price='12.001')]},
    {'prices':[dict(material_id=1,unit_price='12',min_qty='10',max_qty='9')]},
])
def test_invalid_business_scope(env,change):
    c,_,_=env;p=deepcopy(PAYLOAD);p.update(change)
    assert c.post('/api/contracts',json=p,headers=HEAD).status_code==422

def test_files_and_failed_storage_are_atomic(env,monkeypatch):
    c,_,db=env;id=new(c)
    for name,data,expected in [('x.html',b'<script>',422),('../x.pdf',PDF,422),('x.pdf',b'not PDF',422),('x.docx',b'PKfake',422),('x.pdf',b'',413),('x.pdf',b'x'*(storage.MAX_FILE_BYTES+1),413)]:
        assert attach(c,id,filename=name,body=data).status_code==expected
    from fastapi import HTTPException
    def fail(*_):raise HTTPException(503,'storage offline')
    monkeypatch.setattr(storage,'put',fail)
    assert attach(c,id).status_code==503
    with db.connect() as con:
        assert con.execute(select(func.count()).select_from(s.contract_attachment)).scalar()==0
        assert con.execute(select(s.sales_contract.c.version)).scalar()==1

def test_private_storage_request_contract(monkeypatch):
    monkeypatch.setattr(storage,'PRODUCTION',True)
    monkeypatch.setenv('CONTRACT_STORAGE_BACKEND','supabase')
    monkeypatch.setenv('SUPABASE_URL','https://test.supabase.co')
    monkeypatch.setenv('SUPABASE_SECRET_KEY','server-only-test-key')
    monkeypatch.setenv('CONTRACT_STORAGE_BUCKET','erp-contracts')
    calls=[]
    def request(method,url,**kw):
        calls.append((method,url,kw))
        return httpx.Response(200,json={'signedURL':'/object/sign/erp-contracts/1/1/a.pdf?token=test'} if '/sign/' in url else {})
    monkeypatch.setattr(storage.httpx,'request',request)
    storage.put('1/1/a.pdf',PDF,'application/pdf')
    url=storage.signed_url('1/1/a.pdf','合同.pdf')
    assert url.startswith('https://test.supabase.co/storage/v1/object/sign/') and '&download=' in url
    assert calls[0][2]['headers']['Authorization']=='Bearer server-only-test-key'
    assert calls[0][2]['headers']['x-upsert']=='false'
    assert calls[1][2]['json']=={'expiresIn':60}
    storage.remove('1/1/a.pdf');assert calls[2][2]['json']=={'prefixes':['1/1/a.pdf']}
    monkeypatch.setenv('CONTRACT_STORAGE_BACKEND','local')
    with pytest.raises(Exception) as exc:storage.config()
    assert exc.value.status_code==503

def test_remove_attachment_and_missing_file_is_not_downloadable(env):
    c,actor,_=env;id=new(c);f=attach(c,id).json()['id']
    assert c.delete(f'/api/contracts/{id}/attachments/{f}?version=1',headers=HEAD).status_code==409
    r=c.delete(f'/api/contracts/{id}/attachments/{f}?version=2',headers=HEAD)
    assert r.status_code==200 and r.json()['storage_cleaned']
    assert c.get(f'/api/contracts/{id}/attachments/{f}/download').status_code==404
    assert act(c,id,'submit',3).status_code==422

def test_explicit_category_and_service_sku_scope(env):
    c,_,_=env
    p=deepcopy(PAYLOAD);p.update(category_ids=[1],sku_ids=[])
    id=new(c,p);d=c.get(f'/api/contracts/{id}').json()
    assert d['category_ids']==[1] and d['sku_ids']==[]
    p.update(contract_no='SERVICE-SKU',kind='service',prices=[],category_ids=[],sku_ids=[1])
    id=new(c,p);assert c.get(f'/api/contracts/{id}').json()['sku_ids']==[1]
    p.update(contract_no='NO-SCOPE',sku_ids=[])
    assert c.post('/api/contracts',json=p,headers=HEAD).status_code==422
    p.update(contract_no='BAD-SCOPE',category_ids=[999])
    assert c.post('/api/contracts',json=p,headers=HEAD).status_code==422

def test_prices_cannot_escape_selected_sku_scope(env):
    c,_,db=env
    with db.begin() as con:
        con.execute(s.material_category.insert().values(id=2,name='非食用盐',code='NONFOOD',level=1))
        m=dict(con.execute(select(s.material).where(s.material.c.id==1)).mappings().one());m.update(id=2,code='SKU-2',category_id=2)
        con.execute(s.material.insert().values(**m));con.execute(s.material_org.insert().values(material_id=2,company_id=1))
    p=deepcopy(PAYLOAD);p.update(sku_ids=[2])
    assert c.post('/api/contracts',json=p,headers=HEAD).status_code==422

def test_admin_supplement_preserves_approved_contract_and_original_file(env):
    c,actor,_=env;id=new(c);original=attach(c,id).json()['id']
    assert act(c,id,'submit',2).status_code==200
    actor['grants'][1]='admin';assert act(c,id,'approve',3).status_code==200
    actor['grants'][1]='operator'
    url=f'/api/contracts/{id}/attachments?filename=supplement.pdf&version=4&supplement=true'
    assert c.post(url,content=PDF,headers=HEAD).status_code==409
    actor['grants'][1]='admin';r=c.post(url,content=PDF,headers=HEAD);assert r.status_code==201,r.text
    d=c.get(f'/api/contracts/{id}').json()
    assert d['contract']['status']=='approved' and len(d['attachments'])==2
    assert c.get(f'/api/contracts/{id}/attachments/{original}/download').content==PDF
    assert d['events'][-1]['action']=='supplement'
