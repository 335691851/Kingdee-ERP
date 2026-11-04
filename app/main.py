import os,json,csv,io,logging
from pathlib import Path
from datetime import date
from decimal import Decimal
from typing import Annotated
import httpx
from fastapi import FastAPI,Depends,HTTPException,Request,Response
from fastapi.responses import FileResponse,StreamingResponse,HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel,Field,field_validator
from sqlalchemy import select,func,or_,and_,update
from .db import engine,PRODUCTION
from . import schema as s
from .catalog import REGISTRY,MODULES
from .auth import current_user,authorize,token_for_demo,AUTH_MODE,login_email
from .services import get_doc,create_document,transition,settle,now,audit,money

log=logging.getLogger('erp')
app=FastAPI(title='鲁盐集团 ERP · 模拟业务系统',version='1.0.0',docs_url=None if PRODUCTION else '/api/docs',openapi_url='/api/openapi.json')
STATIC=Path(__file__).parent/'static'
app.mount('/assets',StaticFiles(directory=STATIC),name='assets')
User=Annotated[dict,Depends(current_user)]
class Login(BaseModel):username:str;password:str
class Item(BaseModel):
    material_id:int
    qty:Decimal=Field(gt=0,max_digits=24,decimal_places=6)
    unit_price:Decimal=Field(ge=0,max_digits=20,decimal_places=2)
    tax_rate:Decimal=Field(default=Decimal('.09'),ge=0,le=1)
class Create(BaseModel):
    company_id:int;type_code:str;bill_date:str;partner_id:int|None=None;warehouse_id:int|None=None
    lines:list[Item]=Field(min_length=1,max_length=200)
    memo:str=Field(default='',max_length=2000)
    price_includes_tax:bool=True
    department:str='营销部';sales_group:str='省内部菏泽区';payment_terms:str='30天后收款';delivery_method:str='发货'
    ship_from:str='肥城市';ship_to:str='定陶区';ship_address:str='';carrier:str='';vehicle_no:str=''
    @field_validator('bill_date')
    @classmethod
    def valid_date(cls,v):return date.fromisoformat(v).isoformat()
class Action(BaseModel):action:str;version:int=Field(gt=0)
class Settlement(BaseModel):bill_id:int;cash_id:int;amount:Decimal=Field(gt=0)
class Edit(Create):version:int=Field(gt=0)
class CostRun(BaseModel):
    company_id:int;period:str=Field(pattern=r'^\d{4}-(0[1-9]|1[0-2])$')
class CostPool(CostRun):item:str=Field(pattern=r'^(labor|overhead)$');amount:Decimal=Field(gt=0)
class Report(BaseModel):
    completed_qty:Decimal=Field(gt=0);labor_hours:Decimal=Field(gt=0);machine_hours:Decimal=Field(gt=0)
@app.middleware('http')
async def safety(request,call_next):
    if request.method not in ('GET','HEAD','OPTIONS'):
        if request.headers.get('x-erp-client')!='luyan-web':return Response('Missing CSRF request header',status_code=403)
        origin=request.headers.get('origin')
        if origin:
            from urllib.parse import urlsplit
            if urlsplit(origin).netloc!=request.headers.get('host'):return Response('Cross-origin write blocked',status_code=403)
    response=await call_next(request)
    if request.url.path.startswith('/api'):response.headers['Cache-Control']='no-store'
    elif request.url.path.startswith('/assets'):response.headers['Cache-Control']='no-cache'
    response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
    return response
@app.get('/')
def index():
    if not PRODUCTION:return FileResponse(STATIC/'index.html')
    # Render production login configuration before JavaScript loads.
    import re
    html=(STATIC/'index.html').read_text(encoding='utf8')
    html=html.replace('id="username" value="admin"','id="username" value="" placeholder="Supabase 登录邮箱"')
    html=html.replace('id="password" value="luyan-demo-2026"','id="password" value=""')
    html=re.sub(r'<div class="login-note">.*?</div>','<div class="login-note">使用已开通 ERP 法人权限的 Supabase 账户登录。所有历史交易为模拟数据。</div>',html,count=1)
    return HTMLResponse(html)
@app.get('/api/health')
def health():
    try:
        with engine.connect() as c:c.execute(select(s.company.c.id).limit(1))
        return dict(status='ok',auth_mode=AUTH_MODE,data='simulated',database=engine.dialect.name)
    except Exception:
        log.exception('Database health check failed');raise HTTPException(503,'数据库尚未初始化，请执行初始化及播种命令')
@app.post('/api/auth/login')
def login(payload:Login,response:Response):
    if AUTH_MODE=='demo':token=token_for_demo(payload.username,payload.password)
    else:
        url=os.getenv('SUPABASE_URL','').rstrip('/');key=os.getenv('SUPABASE_PUBLISHABLE_KEY','')
        if not url or not key:raise HTTPException(503,'尚未配置 Supabase Auth')
        try:r=httpx.post(url+'/auth/v1/token?grant_type=password',headers={'apikey':key},json={'email':login_email(payload.username),'password':payload.password},timeout=15)
        except httpx.HTTPError:raise HTTPException(503,'登录服务暂不可用')
        if r.status_code!=200:raise HTTPException(401,'邮箱或密码错误')
        token=r.json()['access_token']
    response.set_cookie('erp_session',token,httponly=True,secure=PRODUCTION,samesite='strict',max_age=3600 if PRODUCTION else 28800,path='/')
    return {'ok':True}
@app.post('/api/auth/logout')
def logout(response:Response):response.delete_cookie('erp_session',path='/');return {'ok':True}
@app.get('/api/me')
def me(user:User):return dict(name=user['name'],companies=list(user['grants']),roles=user['grants'],auth_mode=AUTH_MODE)
@app.get('/api/meta')
def meta(user:User):
    with engine.connect() as c:
        companies=[dict(r) for r in c.execute(select(s.company).where(s.company.c.id.in_(authorize(user)))).mappings()]
        parent=s.material_category.alias('parent_category')
        mats=[dict(r) for r in c.execute(select(s.material,s.material_category.c.name.label('category'),parent.c.name.label('category_level1'),s.uom.c.name.label('unit')).select_from(s.material.join(s.material_category,s.material.c.category_id==s.material_category.c.id).join(parent,parent.c.id==s.material_category.c.parent_id).join(s.uom,s.material.c.uom_id==s.uom.c.id))).mappings()]
        categories=[dict(r) for r in c.execute(select(s.material_category).order_by(s.material_category.c.level,s.material_category.c.id)).mappings()]
        partners=[dict(r) for r in c.execute(select(s.partner)).mappings()]
        warehouses=[dict(r) for r in c.execute(select(s.warehouse).where(s.warehouse.c.company_id.in_(authorize(user)))).mappings()]
    return dict(companies=companies,materials=mats,categories=categories,partners=partners,warehouses=warehouses,types=list(REGISTRY.values()),modules=MODULES,data_notice='除附件识别的公司/物料参考外，全部为关联模拟历史数据，非企业真实交易。')
def conditions(user,company_id=None,type_code=None,q='',status='',start='',end=''):
    clauses=[s.document.c.company_id.in_(authorize(user,company_id))]
    if type_code:
        if type_code not in REGISTRY:raise HTTPException(422,'未知单据类型')
        clauses.append(s.document.c.type_code==type_code)
    if q:
        clauses.append(or_(s.document.c.bill_no.contains(q,autoescape=True),s.partner.c.name.contains(q,autoescape=True)))
    if status:clauses.append(s.document.c.status==status)
    if start:clauses.append(s.document.c.bill_date>=date.fromisoformat(start).isoformat())
    if end:clauses.append(s.document.c.bill_date<=date.fromisoformat(end).isoformat())
    return clauses
DOC_FROM=s.document.outerjoin(s.partner,s.document.c.partner_id==s.partner.c.id).join(s.company,s.document.c.company_id==s.company.c.id)
DOC_SELECT=select(s.document,s.partner.c.name.label('partner_name'),s.company.c.name.label('company_name')).select_from(DOC_FROM)
@app.get('/api/documents')
def documents(user:User,company_id:int|None=None,type_code:str|None=None,q:str='',status:str='',start:str='',end:str='',page:int=1,page_size:int=30):
    if page<1 or not 1<=page_size<=200:raise HTTPException(422,'分页范围无效')
    clauses=conditions(user,company_id,type_code,q,status,start,end)
    with engine.connect() as c:
        count=c.execute(select(func.count()).select_from(DOC_FROM).where(*clauses)).scalar()
        rows=[dict(r) for r in c.execute(DOC_SELECT.where(*clauses).order_by(s.document.c.bill_date.desc(),s.document.c.id.desc()).offset((page-1)*page_size).limit(page_size)).mappings()]
        sums=c.execute(select(func.sum(s.document.c.total_cents),func.sum(s.document.c.settled_cents)).select_from(DOC_FROM).where(*clauses)).one()
    return dict(items=rows,total=count,page=page,page_size=page_size,total_cents=sums[0] or 0,settled_cents=sums[1] or 0)
@app.get('/api/documents/{id}')
def detail(id:int,user:User):
    with engine.connect() as c:
        d=get_doc(c,id);authorize(user,d['company_id'])
        lines=[dict(r) for r in c.execute(select(s.document_line,s.material.c.code,s.material.c.name,s.material.c.spec,s.uom.c.name.label('unit'),s.lot.c.lot_no).outerjoin(s.material,s.document_line.c.material_id==s.material.c.id).outerjoin(s.uom,s.material.c.uom_id==s.uom.c.id).outerjoin(s.lot,s.document_line.c.lot_id==s.lot.c.id).where(s.document_line.c.document_id==id)).mappings()]
        terms=c.execute(select(s.sales_terms).where(s.sales_terms.c.document_id==id)).mappings().first()
        links=[dict(r) for r in c.execute(select(s.document_link).where(or_(s.document_link.c.source_id==id,s.document_link.c.target_id==id))).mappings()]
        linkedids={x[k] for x in links for k in ['source_id','target_id']}
        neighbors=[dict(r) for r in c.execute(select(s.document.c.id,s.document.c.bill_no,s.document.c.type_code,s.document.c.status,s.document.c.company_id).where(s.document.c.id.in_(linkedids),s.document.c.company_id.in_(authorize(user)))).mappings()]
        audit_rows=[dict(r) for r in c.execute(select(s.audit_event).where(s.audit_event.c.document_id==id).order_by(s.audit_event.c.id.desc()).limit(50)).mappings()]
    visible={r['id'] for r in neighbors};links=[x for x in links if x['source_id'] in visible and x['target_id'] in visible]
    return dict(document=d,lines=lines,terms=dict(terms) if terms else {},links=links,neighbors=neighbors,audit=audit_rows)
@app.post('/api/documents',status_code=201)
def create(payload:Create,user:User):
    authorize(user,payload.company_id,write=True,finance=payload.type_code in ['ar_bill','ap_bill','receipt','payment','ap_accrual','invoice_received','sales_invoice'])
    with engine.begin() as c:id=create_document(c,payload,user['name'])
    return dict(id=id)
@app.put('/api/documents/{id}')
def edit(id:int,payload:Edit,user:User):
    from .services import build_lines,check_period
    with engine.begin() as c:
        d=get_doc(c,id,True);authorize(user,d['company_id'],write=True,finance=d['type_code'] in ['ar_bill','ap_bill','receipt','payment','ap_accrual','invoice_received','sales_invoice'])
        if d['company_id']!=payload.company_id or d['type_code']!=payload.type_code:raise HTTPException(422,'不能修改单据法人或类型')
        if d['type_code']=='production' and len(payload.lines)!=1:raise HTTPException(422,'一个生产工单只能有一个完工产品')
        if d['status']!='draft' or d['version']!=payload.version:raise HTTPException(409,'只能修改未被他人变更的暂存单据')
        check_period(c,d['company_id'],d['bill_date']);check_period(c,d['company_id'],payload.bill_date)
        if payload.partner_id:
            role='supplier' if d['type_code'].startswith(('purchase','ap','invoice_received')) or d['type_code']=='payment' else 'customer'
            if not c.execute(select(s.partner_role.c.id).where(s.partner_role.c.company_id==d['company_id'],s.partner_role.c.partner_id==payload.partner_id,s.partner_role.c.role==role)).first():raise HTTPException(422,'往来方角色不符')
        if not c.execute(select(s.warehouse.c.id).where(s.warehouse.c.company_id==d['company_id'],s.warehouse.c.id==payload.warehouse_id)).first():raise HTTPException(422,'仓库不属于该法人')
        rows=build_lines(c,d['company_id'],payload.lines,payload.price_includes_tax)
        # A converted draft retains source lineage and cannot change its items/quantities.
        if c.execute(select(s.document_link.c.id).where(s.document_link.c.target_id==id)).first():raise HTTPException(409,'关联生成的草稿保留来源约束，暂不支持修改明细；请审核或保留草稿')
        c.execute(s.document_line.delete().where(s.document_line.c.document_id==id));c.execute(s.document_line.insert(),[dict(x,document_id=id) for x in rows])
        c.execute(s.document.update().where(s.document.c.id==id).values(bill_date=payload.bill_date,partner_id=payload.partner_id,warehouse_id=payload.warehouse_id,net_cents=sum(x['net_cents'] for x in rows),tax_cents=sum(x['tax_cents'] for x in rows),total_cents=sum(x['total_cents'] for x in rows),memo=payload.memo,version=d['version']+1,updated_at=now()))
        c.execute(s.sales_terms.update().where(s.sales_terms.c.document_id==id).values(department=payload.department,sales_group=payload.sales_group,payment_terms=payload.payment_terms,delivery_method=payload.delivery_method,ship_from=payload.ship_from,ship_to=payload.ship_to,ship_address=payload.ship_address,carrier=payload.carrier,vehicle_no=payload.vehicle_no,price_includes_tax=payload.price_includes_tax))
        if d['type_code']=='production':
            bom=c.execute(select(s.bom.c.id).where(s.bom.c.company_id==d['company_id'],s.bom.c.material_id==rows[0]['material_id'])).scalar()
            if not bom:raise HTTPException(422,'该产品无 BOM')
            c.execute(s.production_detail.update().where(s.production_detail.c.document_id==id).values(bom_id=bom,planned_qty=rows[0]['qty']))
        audit(c,d['company_id'],id,user['name'],'edit',d,{'version':d['version']+1})
    return dict(id=id)
@app.post('/api/documents/{id}/action')
def action(id:int,payload:Action,user:User):
    with engine.begin() as c:
        d=get_doc(c,id);authorize(user,d['company_id'],write=True,finance=payload.action in ['approve','post'] or d['type_code'] in ['ar_bill','ap_bill','receipt','payment'])
        return transition(c,id,payload.action,payload.version,user['name'])
@app.post('/api/documents/{id}/downstream')
def downstream(id:int,user:User):
    with engine.begin() as c:
        d=get_doc(c,id,True);authorize(user,d['company_id'],write=True)
        target=REGISTRY[d['type_code']]['downstream']
        if not target:raise HTTPException(422,'此单据没有预设下游')
        authorize(user,d['company_id'],write=True,finance=target in ['ar_bill','ap_bill','receipt','payment','ap_accrual','sales_invoice','invoice_received'])
        if d['status'] not in ['approved','posted','closed']:raise HTTPException(409,'请先审核来源单据')
        existing=c.execute(select(s.document.c.id).join(s.document_link,s.document_link.c.target_id==s.document.c.id).where(s.document_link.c.source_id==id,s.document.c.type_code==target)).scalar()
        if existing:raise HTTPException(409,'已有下游单据，请联查；本版本整单转换不允许重复下推')
        src=list(c.execute(select(s.document_line).where(s.document_line.c.document_id==id)).mappings())
        if target=='material_issue':
            pd=c.execute(select(s.production_detail).where(s.production_detail.c.document_id==id)).mappings().first()
            components=list(c.execute(select(s.bom_line).where(s.bom_line.c.bom_id==pd['bom_id'])).mappings())
            items=[Item(material_id=x['component_id'],qty=Decimal(x['qty_per_ton'])*Decimal(pd['planned_qty']),unit_price=0,tax_rate=0) for x in components]
        else:items=[Item(material_id=x['material_id'],qty=x['qty'],unit_price=Decimal(x['unit_price_cents'])/100,tax_rate=x['tax_rate']) for x in src]
        new=create_document(c,Create(company_id=d['company_id'],type_code=target,bill_date=d['bill_date'],partner_id=d['partner_id'],warehouse_id=d['warehouse_id'],lines=items,memo='由 '+d['bill_no']+' 关联生成'),user['name'])
        c.execute(s.document_link.insert().values(source_id=id,target_id=new,relation='source'))
        # Preserve explicitly selected lot information for one-lot transfers.
        if target!='material_issue':
            newlines=list(c.execute(select(s.document_line.c.id).where(s.document_line.c.document_id==new).order_by(s.document_line.c.line_no)).scalars())
            for lid,old in zip(newlines,src):
                if old['lot_id']:c.execute(s.document_line.update().where(s.document_line.c.id==lid).values(lot_id=old['lot_id']))
    return dict(id=new)
@app.post('/api/settlements')
def settlement(payload:Settlement,user:User):
    with engine.begin() as c:
        bill=get_doc(c,payload.bill_id);authorize(user,bill['company_id'],write=True,finance=True)
        cash=get_doc(c,payload.cash_id);authorize(user,cash['company_id'],write=True,finance=True)
        return dict(id=settle(c,payload.bill_id,payload.cash_id,payload.amount,user['name']))
@app.get('/api/inventory')
def inventory(user:User,company_id:int|None=None,q:str='',page:int=1,page_size:int=30):
    if page<1 or not 1<=page_size<=200:raise HTTPException(422,'分页范围无效')
    clauses=[s.stock_balance.c.company_id.in_(authorize(user,company_id))]
    if q:clauses.append(or_(s.material.c.name.contains(q,autoescape=True),s.material.c.code.contains(q,autoescape=True)))
    base=s.stock_balance.join(s.material,s.stock_balance.c.material_id==s.material.c.id).join(s.warehouse,s.stock_balance.c.warehouse_id==s.warehouse.c.id).join(s.lot,s.stock_balance.c.lot_id==s.lot.c.id).join(s.uom,s.material.c.uom_id==s.uom.c.id)
    parent=s.material_category.alias('parent_category')
    base=base.join(s.material_category,s.material.c.category_id==s.material_category.c.id).join(parent,s.material_category.c.parent_id==parent.c.id)
    with engine.connect() as c:
        count=c.execute(select(func.count()).select_from(base).where(*clauses)).scalar()
        rows=[dict(r) for r in c.execute(select(s.stock_balance,s.material.c.name,s.material.c.code,s.material.c.spec,parent.c.name.label('category_level1'),s.material_category.c.name.label('category'),s.warehouse.c.name.label('warehouse'),s.lot.c.lot_no,s.uom.c.name.label('unit')).select_from(base).where(*clauses).order_by(s.stock_balance.c.id.desc()).offset((page-1)*page_size).limit(page_size)).mappings()]
    return dict(items=rows,total=count)
@app.get('/api/costing')
def costing(user:User,company_id:int|None=None,period:str='',page:int=1):
    if page<1:raise HTTPException(422,'分页范围无效')
    clauses=[s.cost_calculation.c.company_id.in_(authorize(user,company_id))]
    if period:clauses.append(s.cost_calculation.c.period==period)
    with engine.connect() as c:
        count=c.execute(select(func.count()).select_from(s.cost_calculation).where(*clauses)).scalar()
        parent=s.material_category.alias('parent_category')
        rows=[dict(r) for r in c.execute(select(s.cost_calculation,s.material.c.name,s.material.c.code,parent.c.name.label('category_level1'),s.material_category.c.name.label('category'),s.document.c.bill_no).join(s.material,s.cost_calculation.c.material_id==s.material.c.id).join(s.material_category,s.material.c.category_id==s.material_category.c.id).join(parent,s.material_category.c.parent_id==parent.c.id).join(s.document,s.cost_calculation.c.production_id==s.document.c.id).where(*clauses).order_by(s.cost_calculation.c.id.desc()).offset((page-1)*30).limit(30)).mappings()]
    return dict(items=rows,total=count)
@app.post('/api/costing/pools',status_code=201)
def add_cost_pool(payload:CostPool,user:User):
    from .services import check_period
    authorize(user,payload.company_id,write=True,finance=True)
    with engine.begin() as c:
        check_period(c,payload.company_id,payload.period+'-01')
        center=c.execute(select(s.cost_center.c.id).where(s.cost_center.c.company_id==payload.company_id)).scalar()
        if not center:raise HTTPException(422,'尚未设置成本中心')
        id=c.execute(s.cost_pool.insert().values(company_id=payload.company_id,period=payload.period,center_id=center,item=payload.item,amount_cents=money(payload.amount*100))).inserted_primary_key[0]
        audit(c,payload.company_id,None,user['name'],'cost_pool',{},dict(id=id,amount_cents=money(payload.amount*100)))
    return dict(id=id)
@app.post('/api/production/{id}/report')
def production_report(id:int,payload:Report,user:User):
    from .services import check_period
    with engine.begin() as c:
        d=get_doc(c,id,True);authorize(user,d['company_id'],write=True);check_period(c,d['company_id'],d['bill_date'])
        if d['type_code']!='production' or d['status'] not in ('approved','posted'):raise HTTPException(409,'需要已审核或已过账的生产工单')
        pd=c.execute(select(s.production_detail).where(s.production_detail.c.document_id==id)).mappings().first()
        if c.execute(select(s.cost_calculation.c.id).where(s.cost_calculation.c.production_id==id)).first():raise HTTPException(409,'已核算工单不允许更改报工')
        if payload.completed_qty>pd['planned_qty']:raise HTTPException(422,'完工数量超过计划')
        if c.execute(select(s.operation_report.c.id).where(s.operation_report.c.production_id==id)).first():raise HTTPException(409,'已有报工；此版本采用整单一次报工')
        employee=c.execute(select(s.employee.c.id).where(s.employee.c.company_id==d['company_id'])).scalar()
        c.execute(s.operation_report.insert().values(company_id=d['company_id'],production_id=id,employee_id=employee,operation='精制与包装',machine_hours=payload.machine_hours,labor_hours=payload.labor_hours,good_qty=payload.completed_qty,scrap_qty=0))
        c.execute(s.production_detail.update().where(s.production_detail.c.document_id==id).values(completed_qty=payload.completed_qty))
        audit(c,d['company_id'],id,user['name'],'production_report',{},payload.model_dump(mode='json'))
    return dict(ok=True)
@app.post('/api/production/{id}/finish',status_code=201)
def production_finish(id:int,user:User):
    with engine.begin() as c:
        d=get_doc(c,id,True);authorize(user,d['company_id'],write=True)
        if d['type_code']!='production' or d['status'] not in ('approved','posted'):raise HTTPException(409,'需要已审核或已过账工单')
        calc=c.execute(select(s.cost_calculation).where(s.cost_calculation.c.production_id==id)).mappings().first()
        if not calc:raise HTTPException(409,'请先领料过账、报工及执行成本计算')
        if c.execute(select(s.document.c.id).join(s.document_link,s.document_link.c.target_id==s.document.c.id).where(s.document_link.c.source_id==id,s.document.c.type_code=='finished_receipt')).first():raise HTTPException(409,'已生成完工入库单')
        wh=c.execute(select(s.warehouse.c.id).where(s.warehouse.c.company_id==d['company_id'],s.warehouse.c.kind=='产成品库')).scalar()
        new=create_document(c,Create(company_id=d['company_id'],type_code='finished_receipt',bill_date=d['bill_date'],warehouse_id=wh,lines=[Item(material_id=calc['material_id'],qty=calc['output_qty'],unit_price=0,tax_rate=0)],memo='由工单完工生成'),user['name'])
        c.execute(s.document_link.insert().values(source_id=id,target_id=new,relation='source'))
    return dict(id=new)
@app.post('/api/costing/run')
def cost_run(payload:CostRun,user:User):
    from .services import check_period
    authorize(user,payload.company_id,write=True,finance=True)
    cid=payload.company_id;period=payload.period
    with engine.begin() as c:
        # Lock company row to serialize this company's cost runs and new pool consumption.
        c.execute(select(s.company.c.id).where(s.company.c.id==cid).with_for_update()).first()
        check_period(c,cid,period+'-01')
        prods=list(c.execute(select(s.document,s.production_detail.c.completed_qty,s.production_detail.c.planned_qty).join(s.production_detail,s.production_detail.c.document_id==s.document.c.id).where(s.document.c.company_id==cid,s.document.c.type_code=='production',s.document.c.bill_date.startswith(period),s.document.c.status.in_(['approved','posted']))).mappings())
        targets=[];skipped=0
        for p in prods:
            if c.execute(select(s.cost_calculation.c.id).where(s.cost_calculation.c.production_id==p['id'])).first():skipped+=1;continue
            if p['completed_qty']<=0:continue
            if p['completed_qty']!=p['planned_qty']:raise HTTPException(409,'本版按整批完工核算；存在部分完工在产品，需要补充在产品分配规则')
            report=c.execute(select(func.sum(s.operation_report.c.labor_hours),func.sum(s.operation_report.c.machine_hours)).where(s.operation_report.c.production_id==p['id'])).one()
            if not report[0] or not report[1]:raise HTTPException(409,'待核算工单缺少有效人工与机器工时报工')
            issues=list(c.execute(select(s.document.c.id).join(s.document_link,s.document_link.c.target_id==s.document.c.id).where(s.document_link.c.source_id==p['id'],s.document.c.type_code=='material_issue',s.document.c.status=='posted')).scalars())
            if not issues:raise HTTPException(409,'待核算工单缺少已过账领料')
            matcost=c.execute(select(func.sum(s.document_line.c.cost_cents)).where(s.document_line.c.document_id.in_(issues))).scalar() or 0
            material=c.execute(select(s.document_line.c.material_id).where(s.document_line.c.document_id==p['id'])).scalar()
            targets.append(dict(p=p,labor=Decimal(report[0]),overhead=Decimal(report[1]),materialcost=matcost,material=material))
        if not targets:return dict(calculated=0,skipped=skipped)
        calcs=[]
        for t in targets:
            id=c.execute(s.cost_calculation.insert().values(company_id=cid,production_id=t['p']['id'],material_id=t['material'],period=period,output_qty=t['p']['completed_qty'],material_cents=t['materialcost'],labor_cents=0,overhead_cents=0,opening_wip_cents=0,closing_wip_cents=0,total_cents=t['materialcost'],status='calculated',version=1)).inserted_primary_key[0];calcs.append(id)
        for item in ['labor','overhead']:
            pools=list(c.execute(select(s.cost_pool).where(s.cost_pool.c.company_id==cid,s.cost_pool.c.period==period,s.cost_pool.c.item==item).with_for_update()).mappings())
            available=[]
            for pool in pools:
                used=c.execute(select(func.sum(s.cost_allocation.c.allocated_cents)).where(s.cost_allocation.c.pool_id==pool['id'])).scalar() or 0
                if pool['amount_cents']>used:available.append((pool,pool['amount_cents']-used))
            if not available:raise HTTPException(409,'缺少未分配的'+('直接人工' if item=='labor' else '制造费用')+'费用池，请先归集')
            basis=sum(t[item] for t in targets)
            for pool,total in available:
                remaining=total
                for i,t in enumerate(targets):
                    amount=remaining if i==len(targets)-1 else money(Decimal(total)*t[item]/basis);remaining-=amount
                    c.execute(s.cost_allocation.insert().values(pool_id=pool['id'],calculation_id=calcs[i],basis_qty=t[item],allocated_cents=amount))
                    col=s.cost_calculation.c[item+'_cents']
                    c.execute(s.cost_calculation.update().where(s.cost_calculation.c.id==calcs[i]).values({item+'_cents':col+amount,'total_cents':s.cost_calculation.c.total_cents+amount}))
        audit(c,cid,None,user['name'],'cost_run',{},dict(period=period,calculated=len(calcs)))
    return dict(calculated=len(calcs),skipped=skipped)
@app.get('/api/vouchers')
def vouchers(user:User,company_id:int|None=None,page:int=1):
    if page<1:raise HTTPException(422,'分页范围无效')
    clauses=[s.voucher.c.company_id.in_(authorize(user,company_id))]
    with engine.connect() as c:
        count=c.execute(select(func.count()).select_from(s.voucher).where(*clauses)).scalar()
        rows=[dict(r) for r in c.execute(select(s.voucher,func.sum(s.voucher_line.c.debit_cents).label('debit_cents'),func.sum(s.voucher_line.c.credit_cents).label('credit_cents')).join(s.voucher_line).where(*clauses).group_by(*s.voucher.c).order_by(s.voucher.c.id.desc()).offset((page-1)*30).limit(30)).mappings()]
    return dict(items=rows,total=count)
@app.get('/api/vouchers/{id}')
def voucher_detail(id:int,user:User):
    with engine.connect() as c:
        v=c.execute(select(s.voucher).where(s.voucher.c.id==id)).mappings().first()
        if not v:raise HTTPException(404,'凭证不存在')
        authorize(user,v['company_id'])
        rows=[dict(r) for r in c.execute(select(s.voucher_line,s.gl_account.c.code,s.gl_account.c.name).join(s.gl_account).where(s.voucher_line.c.voucher_id==id)).mappings()]
    return dict(voucher=dict(v),lines=rows)
@app.get('/api/profit')
def profit(user:User,company_id:int|None=None,period:str='',level1:int|None=None,level2:int|None=None,salt_origin:str='',packaging:str=''):
    clauses=[s.document.c.company_id.in_(authorize(user,company_id)),s.document.c.type_code=='sales_outbound',s.document.c.status.in_(['posted','closed'])]
    if period:clauses.append(s.document.c.bill_date.startswith(period))
    if level1:clauses.append(s.material_category.c.parent_id==level1)
    if level2:clauses.append(s.material.c.category_id==level2)
    if salt_origin:clauses.append(s.material.c.salt_origin==salt_origin)
    if packaging:clauses.append(s.material.c.packaging==packaging)
    # Exactly one approved AR per whole-document conversion in this small ERP.
    with engine.connect() as c:
        parent=s.material_category.alias('parent_category')
        dims=[parent.c.name.label('category_level1'),s.material_category.c.name.label('category'),s.material.c.id,s.material.c.code,s.material.c.name,s.material.c.salt_origin,s.material.c.packaging]
        rows=[dict(r) for r in c.execute(select(*dims,func.sum(s.document_line.c.qty).label('qty'),func.sum(s.document_line.c.net_cents).label('revenue_cents'),func.sum(s.document_line.c.cost_cents).label('cost_cents')).select_from(s.document_line.join(s.document).join(s.material,s.document_line.c.material_id==s.material.c.id).join(s.material_category,s.material.c.category_id==s.material_category.c.id).join(parent,parent.c.id==s.material_category.c.parent_id)).where(*clauses).group_by(*dims)).mappings()]
    # Report is explicitly shipment-based management margin, not accounting-recognized net profit.
    for r in rows:r['profit_cents']=r['revenue_cents']-r['cost_cents'];r['margin']=round(r['profit_cents']/r['revenue_cents']*100,2) if r['revenue_cents'] else None
    summary={}
    for r in rows:
        key=(r['category_level1'],r['category'])
        group=summary.setdefault(key,dict(category_level1=key[0],category=key[1],qty=Decimal(0),revenue_cents=0,cost_cents=0,profit_cents=0))
        for field in ['qty','revenue_cents','cost_cents','profit_cents']:group[field]+=r[field]
    return dict(items=rows,category_summary=list(summary.values()),basis='已过账销售出库的不含税发出金额 − 出库成本；管理毛利口径，非收入确认口径或净利润；集团汇总未抵销内部交易。海盐/矿盐为来源维度，小包/大包/散装为包装维度，不与分类合计相加；来源待确认单独列示。')
@app.get('/api/dashboard')
def dashboard(user:User,company_id:int|None=None):
    ids=authorize(user,company_id)
    with engine.connect() as c:
        counts={r.type_code:r.n for r in c.execute(select(s.document.c.type_code,func.count().label('n')).where(s.document.c.company_id.in_(ids)).group_by(s.document.c.type_code))}
        amounts={r.type_code:dict(total=r.total or 0,open=r.open or 0) for r in c.execute(select(s.document.c.type_code,func.sum(s.document.c.total_cents).label('total'),func.sum(s.document.c.total_cents-s.document.c.settled_cents).label('open')).where(s.document.c.company_id.in_(ids),s.document.c.type_code.in_(['ar_bill','ap_bill','sales_order','purchase_order'])).group_by(s.document.c.type_code))}
        monthly=[dict(r) for r in c.execute(select(func.substr(s.document.c.bill_date,1,7).label('month'),func.sum(s.document.c.net_cents).label('amount')).where(s.document.c.company_id.in_(ids),s.document.c.type_code=='sales_order').group_by(func.substr(s.document.c.bill_date,1,7)).order_by(func.substr(s.document.c.bill_date,1,7).desc()).limit(12)).mappings()][::-1]
        inv=c.execute(select(func.sum(s.stock_balance.c.cost_cents)).where(s.stock_balance.c.company_id.in_(ids))).scalar() or 0
        costs=c.execute(select(func.count()).select_from(s.cost_calculation).where(s.cost_calculation.c.company_id.in_(ids))).scalar()
    return dict(counts=counts,amounts=amounts,monthly=monthly,inventory_cents=inv,cost_count=costs,is_simulated=True)
@app.get('/api/export')
def export(user:User,company_id:int|None=None,type_code:str='sales_order',q:str='',status:str='',start:str='',end:str=''):
    clauses=conditions(user,company_id,type_code,q,status,start,end)
    with engine.connect() as c:
        rows=list(c.execute(DOC_SELECT.where(*clauses).order_by(s.document.c.id).limit(10000)).mappings())
    out=io.StringIO();writer=csv.writer(out);writer.writerow(['单据编号','法人公司','业务日期','往来单位','状态','未税金额','税额','价税合计','模拟数据'])
    def safe(x):return "'"+x if isinstance(x,str) and x.startswith(('=','+','-','@','\t','\r')) else x
    for r in rows:writer.writerow([safe(r['bill_no']),safe(r['company_name']),r['bill_date'],safe(r['partner_name'] or ''),r['status'],str(Decimal(r['net_cents'])/100),str(Decimal(r['tax_cents'])/100),str(Decimal(r['total_cents'])/100),'是'])
    return Response('\ufeff'+out.getvalue(),media_type='text/csv;charset=utf-8',headers={'Content-Disposition':'attachment; filename="erp-export.csv"','X-Export-Limit':'10000'})
