"""Deterministic, linked SIMULATED history. Run offline, never at server startup.
10,000 complete supply/production/intercompany/distribution cycles by default.
"""
import argparse,sys,json,random
from pathlib import Path
from collections import defaultdict
from datetime import date,timedelta
from decimal import Decimal as D
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sqlalchemy import select,func,text
from app.db import engine
from app import schema as s
from app.catalog import COMPANIES,PRODUCTS,TYPES
from app.materials import CATEGORIES,PRODUCT_IDS,material_definitions,bom_components
from app.services import money,now

ACCOUNTS=[('1002','银行存款'),('1122','应收账款'),('1403','原材料'),('1405','库存商品'),('2202','应付账款'),('222101','进项税额'),('222102','销项税额'),('5001','生产成本'),('6001','主营业务收入'),('6401','主营业务成本'),('2211','应付职工薪酬'),('5101','制造费用')]
def seed(cycles=10000):
    from scripts.init_db import initialize
    initialize()
    with engine.connect() as c:
        if c.execute(select(func.count()).select_from(s.document)).scalar():raise SystemExit('数据库已有业务数据，拒绝重复播种。请使用独立的空演示数据库。')
    ids=defaultdict(int); batch=defaultdict(list)
    def put(table_name,**kw):
        ids[table_name]+=1; row=dict(id=kw.pop('id',ids[table_name]),**kw); batch[table_name].append(row); return row
    # FK dependency order is explicit; table metadata handles schema only.
    order=['company','organization','department','employee','app_user','membership','uom','currency','material_category','material','material_org','partner','partner_role','warehouse','bin_location','lot','bank_account','document_type','document','document_line','document_link','sales_terms','delivery_schedule','payment_schedule','bom','bom_line','production_detail','operation_report','stock_transaction','stock_balance','cost_center','cost_rule','cost_pool','cost_calculation','cost_allocation','settlement','gl_account','ledger','fiscal_period','voucher','voucher_line','audit_event','seed_run']
    def flush():
        with engine.begin() as c:
            for name in order:
                if batch[name]:c.execute(s.M.tables[name].insert(),batch[name]);batch[name].clear()
    for i,(code,name,kind,confirmed) in enumerate(COMPANIES,1):
        put('company',code=code,name=name,kind=kind,legal_name_confirmed=confirmed,parent_id=1 if i>1 else None)
        put('organization',company_id=i,name=name,function='采购/销售/库存/核算'+('/生产' if 2<=i<=5 else ''))
        for dept in ['营销部','综合管理部','财务部','法务部','科技创新部','项目部','生产部']:
            d=put('department',company_id=i,name=dept)
            put('employee',company_id=i,department_id=d['id'],name=['王刚','孙杰辉','张春晓','孙利伟','丁磊','赵明','刘敏'][(d['id']-1)%7])
        for kind in ['原辅料库','产成品库','小包装包材库']:
            w=put('warehouse',company_id=i,name=name.replace('有限公司','')+'·'+kind,kind=kind);put('bin_location',warehouse_id=w['id'],code='A-01')
        put('bank_account',company_id=i,name='人民币结算账户',masked_account='**** **** '+str(8600+i))
        put('ledger',company_id=i,name=name+'主账簿',currency_id=1)
        put('cost_center',company_id=i,name='制盐包装成本中心')
        for item,basis in [('labor','labor_hours'),('overhead','machine_hours')]:put('cost_rule',company_id=i,cost_item=item,allocation_basis=basis)
        for month in range(34):
            y=2024+month//12;m=month%12+1;put('fiscal_period',company_id=i,period=f'{y}-{m:02d}',closed=False)
    u=put('app_user',subject='demo-admin',name='演示管理员',enabled=True)
    for i in range(1,13):put('membership',user_id=u['id'],company_id=i,role='admin')
    for n in ['吨','条','件','小时']:put('uom',name=n)
    put('currency',code='CNY',name='人民币')
    for id,code,name,parent,level in CATEGORIES:
        put('material_category',id=id,code=code,name=name,parent_id=parent,level=level)
    ids['material_category']=max(r[0] for r in CATEGORIES)
    materials={r['id']:r for r in material_definitions()}
    for row in materials.values():put('material',**row)
    ids['material']=max(materials)
    for cid in range(1,13):
        for mid in materials:put('material_org',material_id=mid,company_id=cid)
    for i,(_,name,_,_) in enumerate(COMPANIES,1):put('partner',code='IC'+str(i).zfill(3),name=name,kind='related',related_company_id=i)
    for i in range(1,65):put('partner',code='KH'+str(i).zfill(4),name=['济南','青岛','菏泽','泰安','潍坊','临沂','济宁','枣庄'][(i-1)%8]+f'客户{i:03d}（模拟）',kind='customer',related_company_id=None)
    for i in range(1,17):put('partner',code='GY'+str(i).zfill(4),name=f'原盐包材供应商{i:02d}（模拟）',kind='supplier',related_company_id=None)
    for cid in range(1,13):
        for p in batch['partner']:
            for role in (['customer','supplier'] if p['kind']=='related' else [p['kind']]):put('partner_role',partner_id=p['id'],company_id=cid,role=role)
    for code,label,module,prefix,_ in TYPES:put('document_type',code=code,label=label,module=module,prefix=prefix)
    boms={}
    for cid in range(2,6):
        for mid in PRODUCT_IDS:
            b=put('bom',company_id=cid,material_id=mid,version='V1.0',yield_rate=D('.97'));boms[cid,mid]=b['id']
            for component,amount in bom_components(mid):put('bom_line',bom_id=b['id'],component_id=component,qty_per_ton=amount)
    acct={code:put('gl_account',code=code,name=n)['id'] for code,n in ACCOUNTS}
    flush()
    pools={}; totals=defaultdict(int); pool_entries=[]
    def link(src,tgt,relation='source'):put('document_link',source_id=src['id'],target_id=tgt['id'],relation=relation)
    def mkline(mid,qty,price,cost=0,lotid=None):
        gross=money(D(qty)*D(price));net=money(D(gross)/D('1.13'))
        return dict(material_id=mid,qty=D(qty),unit_price_cents=price,tax_rate=D('.13'),net_cents=net,tax_cents=gross-net,total_cents=gross,cost_cents=cost,lot_id=lotid)
    def doc(cid,code,dt,partner,lines,source=None):
        d=put('document',company_id=cid,type_code=code,bill_no=f'{dict((t[0],t[3]) for t in TYPES)[code]}-{COMPANIES[cid-1][0]}-{dt.replace("-","")}-{ids["document"]+1:07d}',bill_date=dt,status='posted',partner_id=partner,employee_id=(cid-1)*7+1,warehouse_id=(cid-1)*3+(2 if code in ['finished_receipt','sales_order','delivery','sales_outbound','sales_invoice','ar_bill','receipt'] else 1),currency_id=1,net_cents=sum(l['net_cents'] for l in lines),tax_cents=sum(l['tax_cents'] for l in lines),total_cents=sum(l['total_cents'] for l in lines),settled_cents=0,freight_cents=0,version=1,is_simulated=True,memo='关联模拟历史 · 非企业真实交易',created_at=dt+'T09:00:00+08:00',updated_at=dt+'T16:30:00+08:00')
        out=[]
        for j,l in enumerate(lines,1):out.append(put('document_line',document_id=d['id'],line_no=j,**l))
        if source:link(source,d)
        if code in ('sales_order','purchase_order','delivery','sales_outbound','sales_contract'):
            put('sales_terms',document_id=d['id'],department='营销部',sales_group=['省内部菏泽区','华南大区','省外华东区'][cid%3],payment_terms='30天后收款',delivery_method='发货' if cid%2 else '自提',ship_from='肥城市' if cid%2 else '寿光市',ship_to=['定陶区','秀英区','济南市'][cid%3],ship_address='模拟收货地址',carrier='运输服务商（模拟）',vehicle_no='鲁J·DEMO',price_includes_tax=True)
        return d,out
    def movement(d,ls,direction):
        for l in ls:
            wh=d['warehouse_id'];qty=D(l['qty'])*direction;cost=l['cost_cents']*direction
            put('stock_transaction',company_id=d['company_id'],line_id=l['id'],warehouse_id=wh,material_id=l['material_id'],lot_id=l['lot_id'],posted_on=d['bill_date'],qty_delta=qty,cost_delta_cents=cost,posting_key='seed-line:'+str(l['id']))
    def v(d,entries):
        entries=[e for e in entries if e[1]+e[2]>0]
        assert sum(e[1]-e[2] for e in entries)==0
        vr=put('voucher',company_id=d['company_id'],document_id=d['id'],voucher_no='JZ-'+d['bill_no'],posted_on=d['bill_date'],period=d['bill_date'][:7],status='posted',posting_key='seed-doc:'+str(d['id']))
        for code,dr,cr in entries:put('voucher_line',voucher_id=vr['id'],account_id=acct[code],debit_cents=dr,credit_cents=cr)
    def settle_pair(b,c,ratio):
        val=money(D(b['total_cents'])*ratio)
        b['settled_cents']=val;c['settled_cents']=val
        put('settlement',company_id=b['company_id'],bill_id=b['id'],cash_id=c['id'],amount_cents=val,settled_on=c['bill_date'],posting_key='seed-settle:'+str(b['id']))
    rng=random.Random(20261029)
    for i in range(cycles):
        cid=2+i%4; trading=[1,6,7,8,9,10,11,12][i%8];mid=PRODUCT_IDS[i%len(PRODUCT_IDS)]
        dt=(date(2024,1,1)+timedelta(days=(i*1030)//max(cycles,1))).isoformat();period=dt[:7]
        qty=D(rng.randint(80,360))/10; sold=(qty*D('.75')).quantize(D('.000001'))
        input_lots=[];inputs=[]
        for component,amount in bom_components(mid):
            mat=materials[component]
            lotid=put('lot',company_id=cid,material_id=component,lot_no=f'IN{i:06d}-{component}',manufactured_on=dt,expires_on='2030-12-31')['id']
            input_lots.append((component,lotid,(cid-1)*3+1))
            price=mat['list_price_cents']+rng.randrange(max(2,mat['list_price_cents']//8))
            inputs.append(mkline(component,(qty*amount).quantize(D('.000001')),price,lotid=lotid))
        prodlot=put('lot',company_id=cid,material_id=mid,lot_no=f'CP{i:06d}',manufactured_on=dt,expires_on='2030-12-31')['id']
        tradelot=put('lot',company_id=trading,material_id=mid,lot_no=f'IC{i:06d}',manufactured_on=dt,expires_on='2030-12-31')['id']
        supplier=77+i%16;customer=13+i%64
        for l in inputs:l['cost_cents']=l['net_cents']
        prev=None; pd={}
        for code in ['demand','purchase_req','purchase_contract','purchase_order','purchase_receipt','purchase_inbound','ap_accrual','invoice_received','ap_bill','payment']:
            d,ls=doc(cid,code,dt,supplier,inputs,prev);pd[code]=d;prev=d
            if code=='purchase_inbound':
                movement(d,ls,1);v(d,[('1403',d['net_cents'],0),('2202',0,d['net_cents'])])
            if code=='ap_bill':v(d,[('222101',d['tax_cents'],0),('2202',0,d['tax_cents'])])
            if code=='payment':v(d,[('2202',d['total_cents'],0),('1002',0,d['total_cents'])])
        settle_pair(pd['ap_bill'],pd['payment'],D('.8') if i%4==0 else D(1))
        materialcost=sum(l['cost_cents'] for l in inputs);labor=money(qty*(7200+int(mid)*100));overhead=money(qty*(5600+mid*50));totalcost=materialcost+labor+overhead
        prod,pls=doc(cid,'production',dt,None,[mkline(mid,qty,0)])
        put('production_detail',document_id=prod['id'],bom_id=boms[cid,mid],planned_qty=qty,completed_qty=qty,work_center='制盐包装车间',start_date=dt,end_date=dt)
        report=put('operation_report',company_id=cid,production_id=prod['id'],employee_id=(cid-1)*7+7,operation='精制/筛分/包装',machine_hours=qty*D('1.5'),labor_hours=qty*2,good_qty=qty,scrap_qty=0)
        issue,ils=doc(cid,'material_issue',dt,None,inputs,prod);movement(issue,ils,-1);v(issue,[('5001',materialcost,0),('1403',0,materialcost)])
        calc=put('cost_calculation',company_id=cid,production_id=prod['id'],material_id=mid,period=period,output_qty=qty,material_cents=materialcost,labor_cents=labor,overhead_cents=overhead,opening_wip_cents=0,closing_wip_cents=0,total_cents=totalcost,status='final',version=1)
        for item,amount,basis in [('labor',labor,qty*2),('overhead',overhead,qty*D('1.5'))]:
            key=(cid,period,item)
            if key not in pools:
                pools[key]=put('cost_pool',company_id=cid,period=period,center_id=cid,item=item,amount_cents=0)
            pools[key]['amount_cents']+=amount
            put('cost_allocation',pool_id=pools[key]['id'],calculation_id=calc['id'],basis_qty=basis,allocated_cents=amount)
        fin,fls=doc(cid,'finished_receipt',dt,None,[mkline(mid,qty,0,totalcost,prodlot)],prod);movement(fin,fls,1)
        v(fin,[('1405',totalcost,0),('5001',0,materialcost),('2211',0,labor),('5101',0,overhead)])
        transferprice=money(D(totalcost)*D('1.08')/qty*D('1.13'))
        transfer=[mkline(mid,qty,transferprice,totalcost,prodlot)]
        prev=fin; sp={}
        for code in ['sales_contract','sales_order','delivery','sales_outbound','sales_invoice','ar_bill','receipt']:
            d,ls=doc(cid,code,dt,trading,transfer,prev);sp[code]=d;prev=d
            if code=='sales_outbound':movement(d,ls,-1);v(d,[('6401',totalcost,0),('1405',0,totalcost)])
            if code=='ar_bill':v(d,[('1122',d['total_cents'],0),('6001',0,d['net_cents']),('222102',0,d['tax_cents'])])
            if code=='receipt':v(d,[('1002',d['total_cents'],0),('1122',0,d['total_cents'])])
        settle_pair(sp['ar_bill'],sp['receipt'],D(1))
        buylines=[mkline(mid,qty,transferprice,sp['ar_bill']['net_cents'],tradelot)];prev=None;bp={}
        for code in ['purchase_order','purchase_inbound','ap_bill','payment']:
            d,ls=doc(trading,code,dt,cid,buylines,prev);bp[code]=d;prev=d
            if code=='purchase_inbound':
                # Product procurement enters finished-goods warehouse.
                d['warehouse_id']=(trading-1)*3+2
                movement(d,ls,1);v(d,[('1405',d['net_cents'],0),('2202',0,d['net_cents'])])
            if code=='ap_bill':v(d,[('222101',d['tax_cents'],0),('2202',0,d['tax_cents'])])
            if code=='payment':v(d,[('2202',d['total_cents'],0),('1002',0,d['total_cents'])])
        link(sp['sales_order'],bp['purchase_order'],'intercompany');settle_pair(bp['ap_bill'],bp['payment'],D(1))
        soldcost=money(D(bp['ap_bill']['net_cents'])*sold/qty); external=[mkline(mid,sold,materials[mid]['list_price_cents'],soldcost,tradelot)];prev=None;ep={}
        for code in ['sales_order','delivery','sales_outbound','sales_invoice','ar_bill','receipt']:
            d,ls=doc(trading,code,dt,customer,external,prev);ep[code]=d;prev=d
            if code=='sales_order':
                put('delivery_schedule',line_id=ls[0]['id'],due_date=dt,qty=sold,fulfilled_qty=sold)
                put('payment_schedule',document_id=d['id'],due_date=(date.fromisoformat(dt)+timedelta(days=30)).isoformat(),amount_cents=d['total_cents'])
            if code=='sales_outbound':movement(d,ls,-1);v(d,[('6401',soldcost,0),('1405',0,soldcost)])
            if code=='ar_bill':v(d,[('1122',d['total_cents'],0),('6001',0,d['net_cents']),('222102',0,d['tax_cents'])])
            if code=='receipt':v(d,[('1002',d['total_cents'],0),('1122',0,d['total_cents'])])
        settle_pair(ep['ar_bill'],ep['receipt'],D('.7') if i%3==0 else D(1))
        put('stock_balance',company_id=trading,warehouse_id=(trading-1)*3+2,material_id=mid,lot_id=tradelot,qty=qty-sold,reserved_qty=0,cost_cents=bp['ap_bill']['net_cents']-soldcost,version=1)
        # raw and producer finished lots are fully consumed: zero balances retained for traceability.
        for mid0,lot0,wh0 in input_lots+[(mid,prodlot,(cid-1)*3+2)]:put('stock_balance',company_id=cid,warehouse_id=wh0,material_id=mid0,lot_id=lot0,qty=0,reserved_qty=0,cost_cents=0,version=1)
        put('audit_event',company_id=trading,document_id=ep['sales_order']['id'],actor='模拟数据生成器',action='seed_cycle',before_state='{}',after_state=json.dumps({'cycle':i+1,'is_simulated':True}),created_at=dt+'T16:30:00+08:00')
        # Cost pools accumulate over the whole period. Flush these after cycles, not early.
        if (i+1)%200==0:
            pool_entries=batch['cost_pool'];batch['cost_pool']=[]
            allocs=batch['cost_allocation'];batch['cost_allocation']=[]
            # Delay allocation rows too, because their pool FK has not been inserted.
            totals.setdefault('allocations',[]).extend(allocs)
            flush();batch['cost_pool']=pool_entries
            print(f'{i+1}/{cycles} simulated cycles committed',flush=True)
    pending_allocs=totals.get('allocations',[])+batch['cost_allocation'];batch['cost_allocation']=pending_allocs
    put('seed_run',seed_key='luyan-linked-history-v2-taxonomy',created_at=now(),cycles=cycles,is_simulated=True)
    flush()
    # Explicit IDs used for repeatability: advance PostgreSQL sequences before normal inserts.
    if engine.dialect.name=='postgresql':
        with engine.begin() as c:
            for t in s.M.sorted_tables:
                c.execute(text(f"SELECT setval(pg_get_serial_sequence('{t.name}','id'), COALESCE((SELECT MAX(id) FROM {t.name}),0)+1, false)"))
    print('History generation finished. Run python scripts/validate_data.py',flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--cycles',type=int,default=10000);args=p.parse_args()
    if args.cycles<1:raise SystemExit('cycles must be positive')
    seed(args.cycles)
