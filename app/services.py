from datetime import datetime,timezone
from decimal import Decimal,ROUND_HALF_UP
import json,uuid
from fastapi import HTTPException
from sqlalchemy import select,func,update,and_
from . import schema as s
from .catalog import REGISTRY
D=Decimal
def now(): return datetime.now(timezone.utc).isoformat(timespec='seconds')
def money(x): return int(D(str(x)).quantize(D('1'),rounding=ROUND_HALF_UP))
def audit(conn,company_id,docid,actor,action,before,after):
    conn.execute(s.audit_event.insert().values(company_id=company_id,document_id=docid,actor=actor,action=action,before_state=json.dumps(before,ensure_ascii=False,default=str),after_state=json.dumps(after,ensure_ascii=False,default=str),created_at=now()))
def get_doc(conn,id,lock=False):
    q=select(s.document).where(s.document.c.id==id)
    if lock:q=q.with_for_update()
    r=conn.execute(q).mappings().first()
    if not r: raise HTTPException(404,'单据不存在')
    return dict(r)
def check_period(conn,cid,date):
    if conn.execute(select(s.fiscal_period.c.closed).where(s.fiscal_period.c.company_id==cid,s.fiscal_period.c.period==date[:7])).scalar():
        raise HTTPException(409,'该会计期间已结账，不允许修改')
def build_lines(conn,cid,items,inclusive=True):
    result=[]
    for i,item in enumerate(items,1):
        mat=conn.execute(select(s.material).join(s.material_org,s.material_org.c.material_id==s.material.c.id).where(s.material.c.id==item.material_id,s.material_org.c.company_id==cid)).mappings().first()
        if not mat: raise HTTPException(422,'物料不在当前法人可用范围')
        qty=D(str(item.qty)); price=money(D(str(item.unit_price))*100); rate=D(str(item.tax_rate))
        gross=money(qty*price)
        net=money(D(gross)/(1+rate)) if inclusive else gross
        tax=gross-net if inclusive else money(net*rate)
        result.append(dict(line_no=i,material_id=item.material_id,qty=qty,unit_price_cents=price,tax_rate=rate,net_cents=net,tax_cents=tax,total_cents=net+tax,cost_cents=0,lot_id=None))
    return result
def create_document(conn,payload,actor):
    cid=payload.company_id; code=payload.type_code
    if code not in REGISTRY: raise HTTPException(422,'未知单据类型')
    if code=='production' and len(payload.lines)!=1:raise HTTPException(422,'一个生产工单只能有一个完工产品')
    check_period(conn,cid,payload.bill_date)
    if payload.partner_id:
        role='supplier' if code.startswith(('purchase','ap','invoice_received')) or code=='payment' else 'customer'
        if not conn.execute(select(s.partner_role.c.id).where(s.partner_role.c.company_id==cid,s.partner_role.c.partner_id==payload.partner_id,s.partner_role.c.role==role)).first(): raise HTTPException(422,'往来方未分配给当前法人或角色不符')
    wh=payload.warehouse_id or conn.execute(select(s.warehouse.c.id).where(s.warehouse.c.company_id==cid).order_by(s.warehouse.c.id)).scalar()
    if not conn.execute(select(s.warehouse.c.id).where(s.warehouse.c.id==wh,s.warehouse.c.company_id==cid)).first(): raise HTTPException(422,'仓库不属于当前法人')
    lines=build_lines(conn,cid,payload.lines,payload.price_includes_tax)
    num=REGISTRY[code]['prefix']+'-'+str(cid).zfill(4)+'-'+payload.bill_date.replace('-','')+'-'+uuid.uuid4().hex[:10].upper()
    values=dict(company_id=cid,type_code=code,bill_no=num,bill_date=payload.bill_date,status='draft',partner_id=payload.partner_id,employee_id=None,warehouse_id=wh,currency_id=1,net_cents=sum(x['net_cents'] for x in lines),tax_cents=sum(x['tax_cents'] for x in lines),total_cents=sum(x['total_cents'] for x in lines),settled_cents=0,freight_cents=0,version=1,is_simulated=True,memo=payload.memo,created_at=now(),updated_at=now())
    id=conn.execute(s.document.insert().values(**values)).inserted_primary_key[0]
    conn.execute(s.document_line.insert(),[dict(x,document_id=id) for x in lines])
    if code in ('sales_order','sales_contract','purchase_order','delivery','sales_outbound'):
        conn.execute(s.sales_terms.insert().values(document_id=id,department=payload.department,sales_group=payload.sales_group,payment_terms=payload.payment_terms,delivery_method=payload.delivery_method,ship_from=payload.ship_from,ship_to=payload.ship_to,ship_address=payload.ship_address,carrier=payload.carrier,vehicle_no=payload.vehicle_no,price_includes_tax=payload.price_includes_tax))
    if code=='production':
        bom=conn.execute(select(s.bom).where(s.bom.c.company_id==cid,s.bom.c.material_id==lines[0]['material_id'])).mappings().first()
        if not bom: raise HTTPException(422,'当前法人尚无该产品 BOM')
        conn.execute(s.production_detail.insert().values(document_id=id,bom_id=bom['id'],planned_qty=lines[0]['qty'],completed_qty=0,work_center='制盐包装车间',start_date=payload.bill_date,end_date=payload.bill_date))
    audit(conn,cid,id,actor,'create',{},values)
    return id
def voucher_for(conn,doc,lines):
    t=doc['type_code']; net=doc['net_cents']; tax=doc['tax_cents']; total=doc['total_cents']; cost=sum(x['cost_cents'] for x in lines)
    postings=[]
    if t=='purchase_inbound':
        for line in lines:
            kind=conn.execute(select(s.material.c.kind).where(s.material.c.id==line['material_id'])).scalar()
            postings.append(('1405' if kind=='product' else '1403',line['net_cents'],0))
        postings.append(('2202',0,net))
    elif t=='ap_bill':
        # A converted bill recognizes only VAT: net liability was accrued at receipt.
        seen=set(); pending=[doc['id']]; accrued=False
        while pending:
            child=pending.pop()
            if child in seen:continue
            seen.add(child)
            parents=conn.execute(select(s.document.c.id,s.document.c.type_code,s.document.c.status).join(s.document_link,s.document_link.c.source_id==s.document.c.id).where(s.document_link.c.target_id==child)).all()
            for parent in parents:
                if parent.type_code=='purchase_inbound':
                    if parent.status not in ('posted','closed'):raise HTTPException(409,'来源采购入库单尚未过账')
                    accrued=True
                pending.append(parent.id)
        postings=([('222101',tax,0),('2202',0,tax)] if accrued else [('6401',net,0),('222101',tax,0),('2202',0,total)])
    elif t=='material_issue':postings=[('5001',cost,0),('1403',0,cost)]
    elif t=='finished_receipt':
        prod=conn.execute(select(s.document_link.c.source_id).join(s.document,s.document.c.id==s.document_link.c.source_id).where(s.document_link.c.target_id==doc['id'],s.document.c.type_code=='production')).scalar()
        calc=conn.execute(select(s.cost_calculation).where(s.cost_calculation.c.production_id==prod)).mappings().first()
        labor=money(D(calc['labor_cents'])*sum(D(x['qty']) for x in lines)/D(calc['output_qty']))
        overhead=money(D(calc['overhead_cents'])*sum(D(x['qty']) for x in lines)/D(calc['output_qty']))
        postings=[('1405',cost,0),('5001',0,cost-labor-overhead),('2211',0,labor),('5101',0,overhead)]
        conn.execute(s.cost_calculation.update().where(s.cost_calculation.c.id==calc['id']).values(status='final'))
    elif t=='sales_outbound':postings=[('6401',cost,0),('1405',0,cost)]
    elif t=='ar_bill':postings=[('1122',total,0),('6001',0,net),('222102',0,tax)]
    elif t=='receipt':postings=[('1002',total,0),('1122',0,total)]
    elif t=='payment':postings=[('2202',total,0),('1002',0,total)]
    postings=[p for p in postings if p[1]+p[2]>0]
    if not postings:return
    if sum(p[1]-p[2] for p in postings)!=0:raise HTTPException(409,'凭证借贷不平衡')
    vid=conn.execute(s.voucher.insert().values(company_id=doc['company_id'],document_id=doc['id'],voucher_no='JZ-'+doc['bill_no'],posted_on=doc['bill_date'],period=doc['bill_date'][:7],status='posted',posting_key='doc:'+str(doc['id']))).inserted_primary_key[0]
    accounts=dict(conn.execute(select(s.gl_account.c.code,s.gl_account.c.id)).all())
    conn.execute(s.voucher_line.insert(),[dict(voucher_id=vid,account_id=accounts[p[0]],debit_cents=p[1],credit_cents=p[2]) for p in postings])
def post_inventory(conn,doc,lines):
    t=doc['type_code']; incoming=t in ('purchase_inbound','finished_receipt'); cid=doc['company_id']; wh=doc['warehouse_id']
    for line in lines:
        mat=line['material_id']; qty=D(line['qty'])
        if incoming:
            lotid=line['lot_id']
            if not lotid:
                lotid=conn.execute(s.lot.insert().values(company_id=cid,material_id=mat,lot_no=doc['bill_no']+'-'+str(line['line_no']),manufactured_on=doc['bill_date'],expires_on='2030-12-31')).inserted_primary_key[0]
                conn.execute(s.document_line.update().where(s.document_line.c.id==line['id']).values(lot_id=lotid))
            cost=line['net_cents']
            if t=='finished_receipt':
                prod=conn.execute(select(s.document_link.c.source_id).join(s.document,s.document.c.id==s.document_link.c.source_id).where(s.document_link.c.target_id==doc['id'],s.document.c.type_code=='production')).scalar()
                calc=conn.execute(select(s.cost_calculation).where(s.cost_calculation.c.production_id==prod)).mappings().first()
                if not calc:raise HTTPException(409,'需先对来源工单执行成本核算')
                already=conn.execute(select(func.coalesce(func.sum(s.stock_transaction.c.qty_delta),0)).join(s.document_line,s.document_line.c.id==s.stock_transaction.c.line_id).join(s.document_link,s.document_link.c.target_id==s.document_line.c.document_id).where(s.document_link.c.source_id==prod,s.stock_transaction.c.qty_delta>0)).scalar()
                if D(already)+qty>D(calc['output_qty']):raise HTTPException(409,'累计完工入库超过成本核算数量')
                cost=money(D(calc['total_cents'])*qty/D(calc['output_qty']))
            balance=conn.execute(select(s.stock_balance).where(s.stock_balance.c.company_id==cid,s.stock_balance.c.warehouse_id==wh,s.stock_balance.c.material_id==mat,s.stock_balance.c.lot_id==lotid).with_for_update()).mappings().first()
            if balance:
                conn.execute(s.stock_balance.update().where(s.stock_balance.c.id==balance['id']).values(qty=D(balance['qty'])+qty,cost_cents=balance['cost_cents']+cost,version=balance['version']+1))
            else:conn.execute(s.stock_balance.insert().values(company_id=cid,warehouse_id=wh,material_id=mat,lot_id=lotid,qty=qty,reserved_qty=0,cost_cents=cost,version=1))
        else:
            # A line is one lot: callers split multiple lots into multiple lines.
            q=select(s.stock_balance).where(s.stock_balance.c.company_id==cid,s.stock_balance.c.warehouse_id==wh,s.stock_balance.c.material_id==mat,s.stock_balance.c.qty-s.stock_balance.c.reserved_qty>=qty)
            if line['lot_id']:q=q.where(s.stock_balance.c.lot_id==line['lot_id'])
            balance=conn.execute(q.order_by(s.stock_balance.c.lot_id).with_for_update()).mappings().first()
            if not balance:raise HTTPException(409,'库存不足；单行按单批次出库，请拆分批次或选择有库存的仓库')
            lotid=balance['lot_id']; cost=money(D(balance['cost_cents'])*qty/D(balance['qty']))
            conn.execute(s.stock_balance.update().where(s.stock_balance.c.id==balance['id']).values(qty=D(balance['qty'])-qty,cost_cents=balance['cost_cents']-cost,version=balance['version']+1))
        conn.execute(s.document_line.update().where(s.document_line.c.id==line['id']).values(cost_cents=cost,lot_id=lotid))
        line['cost_cents']=cost; line['lot_id']=lotid
        conn.execute(s.stock_transaction.insert().values(company_id=cid,line_id=line['id'],warehouse_id=wh,material_id=mat,lot_id=lotid,posted_on=doc['bill_date'],qty_delta=qty if incoming else -qty,cost_delta_cents=cost if incoming else -cost,posting_key='line:'+str(line['id'])))
def transition(conn,id,action,version,actor):
    doc=get_doc(conn,id,True); check_period(conn,doc['company_id'],doc['bill_date'])
    if doc['version']!=version:raise HTTPException(409,'单据已被修改，请刷新后重试')
    states={'submit':('draft','submitted'),'approve':('submitted','approved'),'post':('approved','posted'),'close':('posted','closed'),'recall':('submitted','draft')}
    if action not in states:raise HTTPException(422,'不支持的操作')
    old,new=states[action]
    if doc['status']!=old:raise HTTPException(409,'当前状态不允许此操作')
    lines=[dict(x) for x in conn.execute(select(s.document_line).where(s.document_line.c.document_id==id)).mappings()]
    if not lines:raise HTTPException(422,'单据必须至少一行')
    if action=='post':
        if doc['type_code'] in ('purchase_inbound','sales_outbound','material_issue','finished_receipt'):post_inventory(conn,doc,lines)
        voucher_for(conn,doc,lines)
    changed=conn.execute(s.document.update().where(s.document.c.id==id,s.document.c.version==version).values(status=new,version=version+1,updated_at=now()))
    if changed.rowcount!=1:raise HTTPException(409,'并发修改，请刷新')
    audit(conn,doc['company_id'],id,actor,action,{'status':old},{'status':new})
    return get_doc(conn,id)
def settle(conn,bill_id,cash_id,amount,actor):
    if bill_id==cash_id:raise HTTPException(422,'不能与自身核销')
    docs={i:get_doc(conn,i,True) for i in sorted([bill_id,cash_id])}; bill=docs[bill_id]; cash=docs[cash_id]
    for d in docs.values():check_period(conn,d['company_id'],d['bill_date'])
    if (bill['type_code'],cash['type_code']) not in [('ar_bill','receipt'),('ap_bill','payment')]:raise HTTPException(422,'核销单据类型不匹配')
    if bill['company_id']!=cash['company_id'] or bill['partner_id']!=cash['partner_id']:raise HTTPException(422,'必须是同一法人、同一往来方')
    if any(d['status'] not in ('posted','closed') for d in docs.values()):raise HTTPException(409,'双方单据必须已过账')
    cents=money(D(str(amount))*100)
    if cents<=0 or any(cents>d['total_cents']-d['settled_cents'] for d in docs.values()):raise HTTPException(409,'核销金额超出未核销余额')
    sid=conn.execute(s.settlement.insert().values(company_id=bill['company_id'],bill_id=bill_id,cash_id=cash_id,amount_cents=cents,settled_on=cash['bill_date'],posting_key=uuid.uuid4().hex)).inserted_primary_key[0]
    for d in docs.values():conn.execute(s.document.update().where(s.document.c.id==d['id']).values(settled_cents=d['settled_cents']+cents,version=d['version']+1))
    audit(conn,bill['company_id'],bill_id,actor,'settle',{},dict(cash_id=cash_id,amount_cents=cents))
    return sid
