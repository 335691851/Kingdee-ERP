"""Resume-safe PDF attachment generation for the explicitly seeded simulation batch.

Uses normal ERP permissions and the deployed upload API. Enter credentials at the
prompt; no password, session or secret key is saved in output or source.
Requires reportlab in an offline authoring environment, not on Vercel.
"""
import argparse,getpass,hashlib,json,os,threading,time
from concurrent.futures import ThreadPoolExecutor,as_completed
from pathlib import Path
from xml.sax.saxutils import escape
import copy,http.cookiejar,urllib.request,urllib.error,urllib.parse
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle,KeepTogether

PREFIX='SIM-HT-20261104-'
KINDS={'goods':'商品价格协议','service':'服务框架协议','mixed':'商品与服务综合协议'}
OUT=Path('work/contract-history-pdfs')
_local=threading.local()

class ApiResponse:
    def __init__(self,status,data):self.status_code=status;self.data=data
    def json(self):return json.loads(self.data)
    def raise_for_status(self):
        if self.status_code>=400:raise RuntimeError(f'ERP HTTP {self.status_code}')

class Session:
    def __init__(self,cookies=None):
        self.cookies=http.cookiejar.CookieJar()
        for cookie in cookies or []:self.cookies.set_cookie(copy.copy(cookie))
        self.opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookies))
    def request(self,method,url,params=None,json=None,data=None,headers=None,timeout=45):
        import json as json_module
        headers=dict(headers or {})
        if params:url+='?'+urllib.parse.urlencode(params)
        if json is not None:data=json_module.dumps(json).encode();headers['Content-Type']='application/json'
        try:
            with self.opener.open(urllib.request.Request(url,data=data,headers=headers,method=method),timeout=timeout) as r:return ApiResponse(r.status,r.read())
        except urllib.error.HTTPError as e:return ApiResponse(e.code,e.read())
    def get(self,url,**kwargs):return self.request('GET',url,**kwargs)
    def post(self,url,**kwargs):return self.request('POST',url,**kwargs)

def pdf_file(d,meta):
    c=d['contract'];path=OUT/(c['contract_no']+meta['suffix']+'.pdf')
    style=ParagraphStyle('body',fontName='STSong-Light',fontSize=9,leading=15,wordWrap='CJK',spaceAfter=7)
    heading=ParagraphStyle('heading',parent=style,fontSize=15,leading=22,textColor=colors.HexColor('#176e5d'),spaceAfter=15)
    def p(v):return Paragraph(escape(str(v or '—')).replace('\n','<br/>'),style)
    story=[Paragraph('模拟合同 / 非真实合约',heading),p(c['title']),p('合同编号：'+c['contract_no']),
        p('所属法人：'+meta['companies'][c['company_id']]['name']),p('适用客户：'+'；'.join(meta['partners'][i]['name'] for i in d['customer_ids'])),
        p('业务责任销售人员：'+meta['employees'].get(c['salesperson_id'],'按ERP表单记录')),
        p(f"签订日期：{c['signed_on']}　有效期：{c['valid_from']} 至 {c['valid_to']}"),
        p('本文件由系统于2026-11-04生成，仅用于演示历史合同数据。不代表已签署文件，不具有任何实际交易或签约含义。'),Spacer(1,8)]
    if meta['suffix']:
        categories=meta['categories']
        def matches(cid):
            seen=set()
            while cid and cid not in seen:
                if cid in d['category_ids']:return True
                seen.add(cid);cid=categories.get(cid,{}).get('parent_id')
            return False
        selected=[m for m in meta['company_materials'][c['company_id']] if m['id'] in d['sku_ids'] or matches(m['category_id'])]
        if not selected:raise ValueError('Contract has no resolved product scope')
        story.extend([Paragraph('适用产品分类与 SKU',heading),p('范围规则：所选分类（含下级分类）与指定SKU的并集；仅适用于所属法人及本合同客户。'),p('选择方式：'+('按分类' if d['category_ids'] else '指定SKU'))])
        if d['category_ids']:story.append(p('所选分类：'+'；'.join(categories[i]['name'] for i in d['category_ids'])))
        scope_rows=[[p(x) for x in ['一级 / 二级分类','SKU编码','产品名称 / 型号规格','单位']]]
        for item in selected:
            m=meta['materials'][item['id']]
            scope_rows.append([p(str(m.get('category_level1',''))+' / '+str(m.get('category',''))),p(m['code']),p(m['name']+'\n规格：'+m['spec']),p(m['unit'])])
        scope_table=Table(scope_rows,colWidths=[105,90,275,45],repeatRows=1,hAlign='LEFT')
        scope_table.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#e9f4ef')),('GRID',(0,0),(-1,-1),.4,colors.HexColor('#d6e3df')),('VALIGN',(0,0),(-1,-1),'TOP'),('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7)]))
        story.extend([scope_table,Spacer(1,15)])
        if c['kind']=='service':story.append(p('本节仅约定服务适用的产品范围，不构成商品报价；服务费用另行确认。'))
    if d['prices']:
        rows=[[p(x) for x in ['物料及规格','数量范围（吨）','含税单价（元/吨）','税率']]]
        for line in d['prices']:
            m=meta['materials'][line['material_id']]
            rows.append([p(m['code']+'\n'+m['name']+'\n规格：'+m['spec']),p(str(line['min_qty'])+' 至 '+('不限' if line['max_qty'] is None else str(line['max_qty']))),p(f"{line['unit_price_cents']/100:,.2f}"),p(f"{float(line['tax_rate'])*100:g}%（模拟）")])
        table=Table(rows,colWidths=[245,88,112,70],repeatRows=1,hAlign='LEFT')
        table.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#e9f4ef')),('GRID',(0,0),(-1,-1),.4,colors.HexColor('#d6e3df')),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),8),('RIGHTPADDING',(0,0),(-1,-1),8),('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7)]))
        story.extend([Paragraph('商品协议价格',heading),table,Spacer(1,15)])
    story.extend([Paragraph('结算与服务条款',heading),p(c['payment_terms']),p(c['service_terms']),KeepTogether([Paragraph('数据来源与使用说明',heading),p(c['notes']),p('签署区：不生成签名或公章。本文件仅为模拟附件。')])])
    def page(canvas,doc):
        canvas.saveState();canvas.setFont('STSong-Light',8);canvas.setFillColor(colors.HexColor('#73817e'))
        canvas.drawString(40,25,'鲁盐 ERP 模拟合同 | '+c['contract_no']);canvas.drawRightString(A4[0]-40,25,str(doc.page))
        canvas.setFont('STSong-Light',35);canvas.setFillColor(colors.Color(.85,.9,.88,alpha=.25));canvas.translate(130,300);canvas.rotate(35);canvas.drawString(0,0,'模拟数据 非真实合同');canvas.restoreState()
    SimpleDocTemplate(str(path),pagesize=A4,leftMargin=40,rightMargin=40,topMargin=35,bottomMargin=45,title=c['title'],author='ERP simulation').build(story,onFirstPage=page,onLaterPages=page)
    return path

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--base',default='https://kingdee-erp-orcin.vercel.app');parser.add_argument('--workers',type=int,default=6);parser.add_argument('--sample-only',action='store_true');parser.add_argument('--ids',default='',help='Optional comma-separated IDs for a verified missing-file retry')
    parser.add_argument('--revision',action='store_true',help='Preserve originals and supplement explicit product-scope PDFs')
    args=parser.parse_args();base=args.base.rstrip('/')
    global OUT
    if args.revision:OUT=Path('work/contract-history-pdfs-scope-v2')
    if base!='https://kingdee-erp-orcin.vercel.app':raise SystemExit('Only the reviewed ERP deployment is supported.')
    OUT.mkdir(parents=True,exist_ok=True);pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
    session=Session();headers={'X-ERP-Client':'luyan-web','Origin':base}
    password=getpass.getpass('ERP administrator password: ')
    r=session.post(base+'/api/auth/login',json={'username':'admin','password':password},headers=headers,timeout=45);password=None
    if r.status_code!=200:raise SystemExit('ERP login failed; no credentials printed.')
    cookies=list(session.cookies)
    meta=session.get(base+'/api/meta',timeout=45).json()
    data={'companies':{r['id']:r for r in meta['companies']},'partners':{r['id']:r for r in meta['partners']},'materials':{r['id']:r for r in meta['materials']},'employees':{}}
    data.update(categories={r['id']:r for r in meta['categories']},company_materials={},suffix='-产品范围版' if args.revision else '')
    for company in meta['companies']:
        options=session.get(base+'/api/contracts/options',params={'company_id':company['id']},timeout=45)
        options.raise_for_status();data['employees'].update({r['id']:r['name'] for r in options.json()['salespeople']});data['company_materials'][company['id']]=options.json()['materials']
    rows=[]
    for page in range(1,11):
        r=session.get(base+'/api/contracts',params={'q':PREFIX,'page':page,'page_size':100},timeout=45);r.raise_for_status();rows.extend(r.json()['items'])
    rows=[r for r in rows if r['contract_no'].startswith(PREFIX)]
    if len(rows)!=1000:raise SystemExit(f'Expected exactly 1000 batch contracts, got {len(rows)}; refusing partial population.')
    if args.ids:
        selected={int(x) for x in args.ids.split(',')}
        rows=[r for r in rows if r['id'] in selected]
        if len(rows)!=len(selected):raise SystemExit('Requested IDs do not all belong to this simulation batch.')
    if args.sample_only:rows=[next(r for r in rows if r['kind']==kind) for kind in KINDS]
    def job(row):
        if not hasattr(_local,'session'):
            _local.session=Session(cookies)
        client=_local.session
        for attempt in range(3):
            try:
                r=client.get(f"{base}/api/contracts/{row['id']}",timeout=45);r.raise_for_status();d=r.json()
                filename=row['contract_no']+data['suffix']+'.pdf'
                existing=next((f for f in d['attachments'] if f['filename']==filename),None)
                if existing:return dict(id=row['id'],status='existing',file_id=existing['id'])
                path=pdf_file(d,data)
                if args.sample_only:return dict(id=row['id'],status='sample',path=str(path))
                r=client.post(f"{base}/api/contracts/{row['id']}/attachments",params={'filename':filename,'version':d['contract']['version'],'supplement':str(args.revision).lower()},data=path.read_bytes(),headers={**headers,'Content-Type':'application/octet-stream'},timeout=60)
                if r.status_code!=201:raise RuntimeError(f'upload HTTP {r.status_code}')
                return dict(id=row['id'],status='uploaded',file_id=r.json()['id'],sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            except Exception as error:
                if attempt==2:return dict(id=row['id'],status='failed',error=type(error).__name__,detail=str(error)[:120])
                time.sleep(1+attempt)
    results=[]
    with ThreadPoolExecutor(max_workers=max(1,min(args.workers,8))) as pool:
        for f in as_completed([pool.submit(job,row) for row in rows]):
            results.append(f.result())
            if len(results)%25==0 or len(results)==len(rows):print(json.dumps({'finished':len(results),'total':len(rows),'failed':sum(x['status']=='failed' for x in results)},ensure_ascii=False),flush=True)
    (OUT/('samples.json' if args.sample_only else 'upload-results-retry.json' if args.ids else 'upload-results.json')).write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf8')
    session.post(base+'/api/auth/logout',json={},headers=headers,timeout=30)
    if any(x['status']=='failed' for x in results):raise SystemExit('Some uploads failed; rerun to resume safely.')

if __name__=='__main__':main()
