"""Commercial contract forms, scoped customers, review and private attachments."""
import hashlib,uuid,logging
from datetime import date
from decimal import Decimal
from typing import Annotated,Literal
from pathlib import Path
from fastapi import APIRouter,Depends,HTTPException,Request,Query
from fastapi.responses import FileResponse,RedirectResponse
from pydantic import BaseModel,Field,model_validator,ConfigDict
from sqlalchemy import select,func,or_,exists
from sqlalchemy.exc import IntegrityError
from . import schema as s
from . import contract_storage as storage
from .db import engine
from .auth import current_user,authorize
from .services import now

router=APIRouter(prefix='/api/contracts',tags=['合同管理'])
User=Annotated[dict,Depends(current_user)]

class Price(BaseModel):
    model_config=ConfigDict(extra='forbid')
    material_id:int
    unit_price:Decimal=Field(ge=0,max_digits=16,decimal_places=2)
    min_qty:Decimal=Field(default=Decimal(0),ge=0,max_digits=18,decimal_places=6)
    max_qty:Decimal|None=Field(default=None,ge=0,max_digits=18,decimal_places=6)
    tax_rate:Decimal=Field(default=Decimal('.09'),ge=0,le=1,max_digits=8,decimal_places=6)
    includes_tax:bool=True
    remark:str=Field(default='',max_length=500)
    @model_validator(mode='after')
    def quantities(self):
        if self.max_qty is not None and self.max_qty<self.min_qty:raise ValueError('数量上限不能低于下限')
        return self

class Contract(BaseModel):
    model_config=ConfigDict(extra='forbid',str_strip_whitespace=True)
    company_id:int;organization_id:int;salesperson_id:int
    contract_no:str=Field(min_length=1,max_length=80)
    title:str=Field(min_length=1,max_length=200)
    kind:Literal['goods','service','mixed']='goods'
    signed_on:date;valid_from:date;valid_to:date
    customer_ids:list[int]=Field(min_length=1,max_length=200)
    prices:list[Price]=Field(default_factory=list,max_length=100)
    payment_terms:str=Field(default='',max_length=500)
    service_terms:str=Field(default='',max_length=20000)
    notes:str=Field(default='',max_length=5000)
    @model_validator(mode='after')
    def dates(self):
        if self.valid_to<self.valid_from:raise ValueError('有效结束日期不能早于开始日期')
        if self.kind in ('goods','mixed') and not self.prices:raise ValueError('商品合同必须填写协议价格')
        if self.kind in ('service','mixed') and not self.service_terms:raise ValueError('服务合同必须填写服务框架条款')
        if len(set(self.customer_ids))!=len(self.customer_ids):raise ValueError('客户不能重复')
        return self

class Revision(Contract):version:int=Field(gt=0)
class Action(BaseModel):
    action:Literal['submit','approve','reject','withdraw','terminate']
    version:int=Field(gt=0)
    note:str=Field(default='',max_length=1000)

def get_contract(c,id,user,write=False):
    row=c.execute(select(s.sales_contract).where(s.sales_contract.c.id==id)).mappings().first()
    if not row:raise HTTPException(404,'合同不存在')
    authorize(user,row['company_id'],write=write)
    if write and user['grants'][row['company_id']]!='admin' and row['owner_id']!=user['id']:
        raise HTTPException(403,'仅提交人或法人管理员可修改此合同')
    return row

def log_event(c,id,user,action,note=''):
    c.execute(s.contract_event.insert().values(contract_id=id,actor_id=user['id'],action=action,note=note,created_at=now()))

def check_scope(c,p):
    for tab,id,label in [(s.organization,p.organization_id,'业务组织'),(s.employee,p.salesperson_id,'销售人员')]:
        if not c.execute(select(tab.c.id).where(tab.c.id==id,tab.c.company_id==p.company_id)).first():
            raise HTTPException(422,label+'不属于当前法人')
    customers=set(c.execute(select(s.partner_role.c.partner_id).join(s.partner,s.partner.c.id==s.partner_role.c.partner_id).where(s.partner_role.c.company_id==p.company_id,s.partner_role.c.role=='customer',s.partner_role.c.partner_id.in_(p.customer_ids),or_(s.partner.c.related_company_id.is_(None),s.partner.c.related_company_id!=p.company_id))).scalars())
    if customers!=set(p.customer_ids):raise HTTPException(422,'所选客户未分配给当前法人')
    mids={x.material_id for x in p.prices}
    valid=set(c.execute(select(s.material_org.c.material_id).join(s.material,s.material.c.id==s.material_org.c.material_id).where(s.material_org.c.company_id==p.company_id,s.material_org.c.material_id.in_(mids),s.material.c.kind=='product')).scalars())
    if mids!=valid:raise HTTPException(422,'协议价格仅支持当前法人的销售成品物料')

def header(p):
    v=p.model_dump(exclude={'customer_ids','prices','version'})
    for key in ('signed_on','valid_from','valid_to'):v[key]=v[key].isoformat()
    return v

def children(c,id,p):
    c.execute(s.contract_customer.insert(),[dict(contract_id=id,partner_id=x) for x in p.customer_ids])
    if p.prices:
        c.execute(s.contract_price.insert(),[dict(contract_id=id,line_no=i+1,material_id=x.material_id,
            unit_price_cents=int(x.unit_price*100),min_qty=x.min_qty,max_qty=x.max_qty,tax_rate=x.tax_rate,
            includes_tax=x.includes_tax,remark=x.remark) for i,x in enumerate(p.prices)])

def claim(c,row,version,**values):
    r=c.execute(s.sales_contract.update().where(s.sales_contract.c.id==row['id'],s.sales_contract.c.version==version).values(version=version+1,updated_at=now(),**values))
    if r.rowcount!=1:raise HTTPException(409,'合同已被修改，请刷新后重试')

@router.get('/options')
def options(user:User,company_id:int):
    authorize(user,company_id)
    with engine.connect() as c:
        def rows(query):return [dict(x) for x in c.execute(query).mappings()]
        return dict(organizations=rows(select(s.organization).where(s.organization.c.company_id==company_id)),
            salespeople=rows(select(s.employee).where(s.employee.c.company_id==company_id)),
            customers=rows(select(s.partner.c.id,s.partner.c.name).join(s.partner_role,s.partner_role.c.partner_id==s.partner.c.id).where(s.partner_role.c.company_id==company_id,s.partner_role.c.role=='customer',or_(s.partner.c.related_company_id.is_(None),s.partner.c.related_company_id!=company_id))),
            materials=rows(select(s.material,s.uom.c.name.label('unit')).join(s.material_org,s.material_org.c.material_id==s.material.c.id).join(s.uom).where(s.material_org.c.company_id==company_id,s.material.c.kind=='product')),
            max_file_bytes=storage.MAX_FILE_BYTES)

@router.get('')
def listing(user:User,company_id:int|None=None,q:str=Query('',max_length=100),status:str='',page:int=Query(1,ge=1),page_size:int=Query(30,ge=1,le=100)):
    ids=authorize(user,company_id)
    clauses=[s.sales_contract.c.company_id.in_(ids)]
    if status:clauses.append(s.sales_contract.c.status==status)
    if q:
        customer=exists(select(s.contract_customer.c.id).join(s.partner,s.partner.c.id==s.contract_customer.c.partner_id).where(s.contract_customer.c.contract_id==s.sales_contract.c.id,s.partner.c.name.contains(q,autoescape=True)))
        clauses.append(or_(s.sales_contract.c.title.contains(q,autoescape=True),s.sales_contract.c.contract_no.contains(q,autoescape=True),customer))
    with engine.connect() as c:
        total=c.execute(select(func.count()).select_from(s.sales_contract).where(*clauses)).scalar()
        rows=c.execute(select(s.sales_contract,s.organization.c.name.label('organization_name'),s.employee.c.name.label('salesperson_name')).join(s.organization).join(s.employee).where(*clauses).order_by(s.sales_contract.c.id.desc()).offset((page-1)*page_size).limit(page_size)).mappings()
        return dict(total=total,items=[dict(x) for x in rows])

@router.post('',status_code=201)
def create(p:Contract,user:User):
    authorize(user,p.company_id,write=True)
    try:
        with engine.begin() as c:
            check_scope(c,p)
            id=c.execute(s.sales_contract.insert().values(**header(p),owner_id=user['id'],status='draft',version=1,created_at=now(),updated_at=now())).inserted_primary_key[0]
            children(c,id,p);log_event(c,id,user,'create')
    except IntegrityError:raise HTTPException(409,'当前法人下合同编号已存在，请核对后重试') from None
    return dict(id=id,version=1)

@router.get('/{id}')
def detail(id:int,user:User):
    with engine.connect() as c:
        row=get_contract(c,id,user)
        def rows(tab):return [dict(x) for x in c.execute(select(tab).where(tab.c.contract_id==id).order_by(tab.c.id)).mappings()]
        files=rows(s.contract_attachment)
        for f in files:f.pop('object_key');f.pop('sha256')
        owner=c.execute(select(s.app_user.c.name).where(s.app_user.c.id==row['owner_id'])).scalar()
        events=[dict(x) for x in c.execute(select(s.contract_event,s.app_user.c.name.label('actor_name')).join(s.app_user,s.app_user.c.id==s.contract_event.c.actor_id).where(s.contract_event.c.contract_id==id).order_by(s.contract_event.c.id)).mappings()]
        return dict(contract=dict(row),owner_name=owner,customer_ids=[x['partner_id'] for x in rows(s.contract_customer)],prices=rows(s.contract_price),attachments=files,events=events,can_edit=user['grants'][row['company_id']]!='viewer' and (row['owner_id']==user['id'] or user['grants'][row['company_id']]=='admin'))

@router.put('/{id}')
def edit(id:int,p:Revision,user:User):
    try:
        with engine.begin() as c:
            row=get_contract(c,id,user,write=True)
            if row['company_id']!=p.company_id:raise HTTPException(422,'已建合同不能变更所属法人')
            if row['status'] not in ('draft','rejected'):raise HTTPException(409,'仅草稿或退回合同可修改')
            check_scope(c,p);claim(c,row,p.version,**header(p))
            c.execute(s.contract_customer.delete().where(s.contract_customer.c.contract_id==id))
            c.execute(s.contract_price.delete().where(s.contract_price.c.contract_id==id))
            children(c,id,p);log_event(c,id,user,'edit')
    except IntegrityError:raise HTTPException(409,'合同编号已存在') from None
    return dict(id=id,version=p.version+1)

@router.post('/{id}/action')
def action(id:int,p:Action,user:User):
    with engine.begin() as c:
        row=get_contract(c,id,user,write=p.action in ('submit','withdraw'))
        if p.action in ('approve','reject','terminate') and user['grants'][row['company_id']]!='admin':raise HTTPException(403,'合同审核和终止需要法人管理员权限')
        transitions={'submit':(('draft','rejected'),'submitted'),'withdraw':(('submitted',),'draft'),
                     'approve':(('submitted',),'approved'),'reject':(('submitted',),'rejected'),'terminate':(('approved',),'terminated')}
        states,target=transitions[p.action]
        if row['status'] not in states:raise HTTPException(409,'当前合同状态不能执行该操作')
        if p.action in ('reject','terminate') and not p.note.strip():raise HTTPException(422,'请填写退回或终止原因')
        if p.action=='submit' and not c.execute(select(s.contract_attachment.c.id).where(s.contract_attachment.c.contract_id==id)).first():raise HTTPException(422,'请先上传至少一份合同附件')
        claim(c,row,p.version,status=target);log_event(c,id,user,p.action,p.note)
    return dict(id=id,status=target,version=p.version+1)

@router.post('/{id}/attachments',status_code=201)
async def upload(id:int,request:Request,user:User,filename:str,version:int=Query(...,gt=0)):
    # Authorize before accepting a body; cap streamed bytes even without Content-Length.
    with engine.connect() as c:
        row=get_contract(c,id,user,write=True)
        if row['status'] not in ('draft','rejected'):raise HTTPException(409,'仅草稿或退回合同可上传附件')
        if row['version']!=version:raise HTTPException(409,'合同已被修改，请刷新后重试')
    data=bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data)>storage.MAX_FILE_BYTES:raise HTTPException(413,'单个附件不得超过 3 MB')
    content_type=storage.validate_file(filename,data)
    object_key=f"{row['company_id']}/{id}/{uuid.uuid4().hex}{Path(filename).suffix.lower()}"
    storage.put(object_key,bytes(data),content_type)
    try:
        with engine.begin() as c:
            row=get_contract(c,id,user,write=True)
            if row['status'] not in ('draft','rejected'):raise HTTPException(409,'合同状态已变更，请刷新')
            claim(c,row,version)
            count=c.execute(select(func.count()).select_from(s.contract_attachment).where(s.contract_attachment.c.contract_id==id)).scalar()
            if count>=20:raise HTTPException(422,'每份合同最多 20 个附件')
            fid=c.execute(s.contract_attachment.insert().values(contract_id=id,object_key=object_key,filename=filename,content_type=content_type,size_bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),uploaded_by=user['id'],created_at=now())).inserted_primary_key[0]
            log_event(c,id,user,'upload',filename)
    except Exception:
        try:storage.remove(object_key)
        except Exception:logging.getLogger('erp').warning('Contract upload compensation failed; check storage for orphan object')
        raise
    return dict(id=fid,version=version+1)

@router.get('/{id}/attachments/{file_id}/download')
def download(id:int,file_id:int,user:User):
    with engine.connect() as c:
        get_contract(c,id,user)
        row=c.execute(select(s.contract_attachment).where(s.contract_attachment.c.id==file_id,s.contract_attachment.c.contract_id==id)).mappings().first()
        if not row:raise HTTPException(404,'附件不存在')
    if storage.config()[0]=='local':
        path=storage.local_path(row['object_key'])
        if not path.is_file():raise HTTPException(404,'附件文件不存在，请联系管理员')
        return FileResponse(path,media_type=row['content_type'],filename=row['filename'],headers={'X-Content-Type-Options':'nosniff'})
    return RedirectResponse(storage.signed_url(row['object_key'],row['filename']),status_code=303)

@router.delete('/{id}/attachments/{file_id}')
def delete_attachment(id:int,file_id:int,user:User,version:int=Query(...,gt=0)):
    with engine.begin() as c:
        row=get_contract(c,id,user,write=True)
        if row['status'] not in ('draft','rejected'):raise HTTPException(409,'仅草稿或退回合同可移除附件')
        file=c.execute(select(s.contract_attachment).where(s.contract_attachment.c.id==file_id,s.contract_attachment.c.contract_id==id)).mappings().first()
        if not file:raise HTTPException(404,'附件不存在')
        claim(c,row,version)
        c.execute(s.contract_attachment.delete().where(s.contract_attachment.c.id==file_id))
        log_event(c,id,user,'remove_attachment',file['filename'])
    # Commit permission/metadata removal first. A storage failure leaves an inaccessible
    # orphan, not a live attachment pointing at a missing object.
    cleaned=True
    try:storage.remove(file['object_key'])
    except Exception:
        cleaned=False
        logging.getLogger('erp').warning('Contract attachment removed; storage cleanup pending for attachment id=%s',file_id)
    return dict(ok=True,version=version+1,storage_cleaned=cleaned)
