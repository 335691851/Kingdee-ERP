'use strict';
const contractLabels={draft:'草稿',submitted:'待审核',approved:'已审核',rejected:'已退回',terminated:'已终止'};
const contractKinds={goods:'商品价格协议',service:'服务框架协议',mixed:'商品与服务综合协议'};
const contractTime=v=>new Date(v).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',hour12:false});
const contractActions={submit:'提交审核',approve:'审核通过',reject:'退回修改',withdraw:'撤回',terminate:'终止合同'};
function contractStatus(c){const expired=c.valid_to<new Date().toLocaleDateString('sv-SE',{timeZone:'Asia/Shanghai'})&&c.status==='approved';return `<span class="status ${esc(c.status)}">${contractLabels[c.status]}${expired?' · 已到期':''}</span>`}
function contractOption(rows,selected){return rows.map(r=>`<option value="${r.id}" ${Number(selected)===r.id?'selected':''}>${esc(r.name)}</option>`).join('')}
async function renderContracts(){
 loading();breadcrumb('客户合同档案');
 try{
  const d=await api('/contracts?'+params({q:state.q,status:state.status}));
  if(state.tabs.find(t=>t.key===state.tab)?.kind!=='contracts')return;
  $('page').innerHTML=`<div class="title-row"><div><h1 class="page-title">客户合同档案</h1><p class="page-subtitle">销售人员提交 · 商品合约价格 / 服务框架 · 按法人授权管理</p></div><span class="period-pill">${state.company?esc(cname(Number(state.company))):'全部授权法人'}</span></div>
  <div class="panel"><div class="toolbar"><button class="primary" id="newContract">新增合同</button><button id="reloadContracts">刷新</button><span class="spacer"></span><input id="contractSearch" class="search-box" placeholder="合同编号 / 名称 / 客户" value="${esc(state.q)}"><select id="contractStatus"><option value="">全部状态</option>${Object.entries(contractLabels).map(([k,v])=>`<option value="${k}" ${state.status===k?'selected':''}>${v}</option>`).join('')}</select><button id="findContracts">查询</button></div>
  <div class="list-summary"><span>共 ${qty(d.total)} 份合同</span><span>独立合同档案 · 协议价格经审核后留档，不自动覆盖销售单价</span></div>
  <div class="table-wrap"><table><thead><tr>${['合同编号','合同名称','状态','所属法人','业务组织','销售人员','合同类型','有效开始','有效结束','最近更新'].map(x=>`<th>${x}</th>`).join('')}</tr></thead><tbody>${d.items.map(c=>`<tr><td><a data-contract="${c.id}">${esc(c.contract_no)}</a></td><td>${esc(c.title)}</td><td>${contractStatus(c)}</td><td>${esc(cname(c.company_id))}</td><td>${esc(c.organization_name)}</td><td>${esc(c.salesperson_name)}</td><td>${contractKinds[c.kind]}</td><td>${c.valid_from}</td><td>${c.valid_to}</td><td>${esc(contractTime(c.updated_at))}</td></tr>`).join('')||'<tr><td colspan="10" class="empty">暂无合同，选择所属法人后可新增合同并上传附件。</td></tr>'}</tbody></table></div>${pager(d.total)}</div>`;
  bind('newContract','click',()=>contractForm());bind('reloadContracts','click',renderContracts);
  bind('findContracts','click',()=>{state.q=$('contractSearch').value;state.status=$('contractStatus').value;state.page=1;renderContracts()});
  bind('contractSearch','keydown',e=>{if(e.key==='Enter')$('findContracts').click()});
  $('page').querySelectorAll('[data-contract]').forEach(b=>b.onclick=()=>viewContract(Number(b.dataset.contract)));
  bindPager(d.total,renderContracts);
 }catch(e){$('page').innerHTML=`<div class="panel empty error">${esc(e.message)}</div>`}
}
async function contractForm(existing=null){
 try{
  const c=existing?.contract||{};
  const cid=c.company_id||Number(state.company);
  if(!cid){toast('请先在右上角选择合同所属法人',true);return}
  if(state.user.roles[cid]==='viewer'){toast('当前法人为只读权限',true);return}
  const options=await api('/contracts/options?company_id='+cid);
  const today=new Date().toLocaleDateString('sv-SE',{timeZone:'Asia/Shanghai'});
  const field=(label,name,value,type='text',extra='')=>`<label>${label}<input name="${name}" type="${type}" value="${esc(value||'')}" ${extra}></label>`;
  breadcrumb(existing?'修改合同':'新增合同');
  $('page').innerHTML=`<div class="title-row"><div><h1 class="page-title">${existing?'修改':'新增'}客户合同</h1><p class="page-subtitle">${esc(cname(cid))} · 保存草稿后上传附件，再提交审核</p></div><button id="cancelContract">返回列表</button></div>
  <form id="contractForm"><div class="panel"><div class="panel-head"><h3>基本信息</h3><span>${existing?contractStatus(c):'草稿'}</span></div><div class="form-grid contract-form-grid">
  ${field('合同编号 *','contract_no',c.contract_no,'text','required maxlength="80"')}${field('合同名称 *','title',c.title,'text','required maxlength="200"')}
  <label>业务组织 *<select name="organization_id" required>${contractOption(options.organizations,c.organization_id)}</select></label>
  <label>销售人员 *<select name="salesperson_id" required>${contractOption(options.salespeople,c.salesperson_id)}</select></label>
  <label>合同类型 *<select name="kind">${Object.entries(contractKinds).map(([k,v])=>`<option value="${k}" ${c.kind===k?'selected':''}>${v}</option>`).join('')}</select></label>
  ${field('签订日期 *','signed_on',c.signed_on||today,'date','required')}${field('有效开始 *','valid_from',c.valid_from||today,'date','required')}${field('有效结束 *','valid_to',c.valid_to,'date','required')}
  <label class="contract-wide">结算 / 收款条件<textarea name="payment_terms" maxlength="500" rows="2">${esc(c.payment_terms)}</textarea></label></div></div>
  <div class="panel"><div class="panel-head"><h3>适用客户范围 *</h3><span>仅列出当前法人已分配的客户</span></div><div class="contract-customer-search"><input id="customerSearch" placeholder="筛选客户名称"><span id="customerCount"></span></div><div class="contract-customers">${options.customers.map(p=>`<label data-customer-name="${esc(p.name)}"><input type="checkbox" name="customers" value="${p.id}" ${existing?.customer_ids.includes(p.id)?'checked':''}>${esc(p.name)}</label>`).join('')||'<p class="helper">当前法人尚未分配客户，需先维护客户范围。</p>'}</div></div>
  <div class="panel"><div class="panel-head"><h3>商品合约价格</h3><button type="button" id="addContractPrice">增加商品</button></div><p class="helper contract-padding">价格单位与物料计量单位一致；盐品为元/吨。数量区间包含上下限。价格来源是人工录入，物料目录价仅作默认参考。</p><div class="contract-price-wrap"><table><thead><tr>${['商品 / 规格','单位','协议单价（元）','数量下限','数量上限（可空）','税率（%）','含税','备注','操作'].map(x=>`<th>${x}</th>`).join('')}</tr></thead><tbody id="contractPrices"></tbody></table></div></div>
  <div class="panel"><div class="panel-head"><h3>服务框架与补充说明</h3></div><div class="form-grid contract-form-grid"><label class="contract-wide">服务范围、交付标准、双方责任、违约条款<textarea name="service_terms" maxlength="20000" rows="6">${esc(c.service_terms)}</textarea></label><label class="contract-wide">补充说明<textarea name="notes" maxlength="5000" rows="3">${esc(c.notes)}</textarea></label></div></div>
  <div class="toolbar"><button type="submit" class="primary" id="saveContract">保存草稿并管理附件</button><span class="helper">附件在保存后上传，提交审核前至少上传一份。</span></div></form>`;
  bind('cancelContract','click',renderContracts);
  const updateCount=()=>{$('customerCount').textContent='已选 '+$('contractForm').querySelectorAll('[name=customers]:checked').length+' 个客户'};
  $('contractForm').querySelectorAll('[name=customers]').forEach(x=>x.onchange=updateCount);updateCount();
  bind('customerSearch','input',()=>{$('contractForm').querySelectorAll('[data-customer-name]').forEach(x=>x.hidden=!x.dataset.customerName.includes($('customerSearch').value))});
  function addPrice(p={}){
   if(!options.materials.length){toast('该法人未分配销售商品',true);return}
   const m=options.materials.find(x=>x.id===p.material_id)||options.materials[0];
   const tr=document.createElement('tr');
   tr.innerHTML=`<td><select class="cp-material" aria-label="协议商品">${options.materials.map(x=>`<option value="${x.id}" ${m.id===x.id?'selected':''}>${esc(x.code+' '+x.name+' / '+x.spec)}</option>`).join('')}</select></td><td class="cp-unit">${esc(m.unit)}</td><td><input aria-label="协议单价" class="cp-price" type="number" required min="0" step=".01" value="${p.unit_price_cents==null?m.list_price_cents/100:p.unit_price_cents/100}"></td><td><input aria-label="数量下限" class="cp-min" type="number" required min="0" step=".000001" value="${esc(p.min_qty??0)}"></td><td><input aria-label="数量上限" class="cp-max" type="number" min="0" step=".000001" value="${esc(p.max_qty??'')}"></td><td><input aria-label="税率百分比" class="cp-tax" type="number" required min="0" max="100" step=".0001" value="${p.tax_rate==null?9:Number(p.tax_rate)*100}"></td><td><input aria-label="价格含税" class="cp-inclusive" type="checkbox" ${p.includes_tax!==false?'checked':''}></td><td><input aria-label="价格备注" class="cp-remark" maxlength="500" value="${esc(p.remark)}"></td><td><button type="button">删除</button></td>`;
   tr.querySelector('button').onclick=()=>tr.remove();
   tr.querySelector('.cp-material').onchange=e=>{const mat=options.materials.find(x=>x.id===Number(e.target.value));tr.querySelector('.cp-unit').textContent=mat.unit;tr.querySelector('.cp-price').value=mat.list_price_cents/100};
   $('contractPrices').append(tr);
  }
  (existing?.prices||(c.kind==='service'?[]:[{}])).forEach(addPrice);bind('addContractPrice','click',()=>addPrice());
  const saveContract=run(async e=>{
   // preventDefault must run before the async handler can yield.
   e.preventDefault();
   const f=new FormData($('contractForm'));const payload=Object.fromEntries([...f.entries()].filter(([k])=>k!=='customers'));
   Object.assign(payload,{company_id:cid,organization_id:Number(f.get('organization_id')),salesperson_id:Number(f.get('salesperson_id')),customer_ids:f.getAll('customers').map(Number),prices:[...$('contractPrices').children].map(tr=>({material_id:Number(tr.querySelector('.cp-material').value),unit_price:tr.querySelector('.cp-price').value,min_qty:tr.querySelector('.cp-min').value,max_qty:tr.querySelector('.cp-max').value||null,tax_rate:String(Number(tr.querySelector('.cp-tax').value)/100),includes_tax:tr.querySelector('.cp-inclusive').checked,remark:tr.querySelector('.cp-remark').value}))});
   if(!payload.customer_ids.length)throw Error('请至少选择一个适用客户');
   if(existing)payload.version=c.version;
   const result=await api('/contracts'+(existing?'/'+c.id:''),{method:existing?'PUT':'POST',body:JSON.stringify(payload)});
   toast('合同已保存，请上传附件并提交审核');await viewContract(result.id);
  });
  $('contractForm').onsubmit=e=>{e.preventDefault();saveContract(e)};
 }catch(e){toast(e.message,true)}
}
async function viewContract(id){
 loading();breadcrumb('合同详情');
 try{
  const d=await api('/contracts/'+id),c=d.contract;
  const role=state.user.roles[c.company_id];const editing=d.can_edit&&['draft','rejected'].includes(c.status);
  const actions=[];
  if(d.can_edit&&['draft','rejected'].includes(c.status))actions.push('submit');
  if(d.can_edit&&c.status==='submitted')actions.push('withdraw');
  if(role==='admin'&&c.status==='submitted')actions.push('approve','reject');
  if(role==='admin'&&c.status==='approved')actions.push('terminate');
  const options=await api('/contracts/options?company_id='+c.company_id);
  const val=(label,value)=>`<div><small>${label}</small><p>${esc(value||'—')}</p></div>`;
  $('page').innerHTML=`<div class="title-row"><div><h1 class="page-title">${esc(c.title)}</h1><p class="page-subtitle">${esc(c.contract_no)}　${esc(cname(c.company_id))}</p></div>${contractStatus(c)}</div><div class="panel"><div class="toolbar"><button id="backContracts">返回列表</button>${editing?'<button id="editContract">修改表单</button>':''}${actions.map(a=>`<button class="${a==='submit'?'primary':''}" data-contract-action="${a}">${contractActions[a]}</button>`).join('')}</div><div class="detail-grid contract-details">${val('业务组织',options.organizations.find(x=>x.id===c.organization_id)?.name)}${val('销售人员',options.salespeople.find(x=>x.id===c.salesperson_id)?.name)}${val('合同类型',contractKinds[c.kind])}${val('签订日期',c.signed_on)}${val('有效开始',c.valid_from)}${val('有效结束',c.valid_to)}${val('提交账户',d.owner_name)}${val('版本',String(c.version))}</div></div>
  <div class="panel"><div class="panel-head"><h3>适用客户（${d.customer_ids.length}）</h3></div><div class="contract-padding">${d.customer_ids.map(x=>`<span class="contract-chip">${esc(pname(x))}</span>`).join('')}</div></div>
  <div class="panel"><div class="panel-head"><h3>商品合约价格</h3></div><div class="contract-price-wrap"><table><thead><tr>${['商品','型号规格','单位','协议单价','数量范围','税率','价格口径','备注'].map(x=>`<th>${x}</th>`).join('')}</tr></thead><tbody>${d.prices.map(p=>{const m=state.meta.materials.find(x=>x.id===p.material_id);return `<tr><td>${esc(m?.name)}</td><td>${esc(m?.spec)}</td><td>${esc(m?.unit)}</td><td>${money(p.unit_price_cents)}</td><td>${qty(p.min_qty)} ～ ${p.max_qty==null?'不限':qty(p.max_qty)}</td><td>${Number(p.tax_rate)*100}%</td><td>${p.includes_tax?'含税':'不含税'}</td><td>${esc(p.remark)}</td></tr>`}).join('')||'<tr><td colspan="8" class="empty">此合同无商品价格明细</td></tr>'}</tbody></table></div></div>
  <div class="panel"><div class="panel-head"><h3>合同条款</h3></div><div class="contract-padding contract-terms"><h4>结算 / 收款条件</h4><p>${esc(c.payment_terms||'—')}</p><h4>服务框架条款</h4><p>${esc(c.service_terms||'—')}</p><h4>补充说明</h4><p>${esc(c.notes||'—')}</p></div></div>
  <div class="panel"><div class="panel-head"><h3>合同附件（${d.attachments.length}/20）</h3><small>PDF / Word / Excel / JPG / PNG，每份不超过 3 MB</small></div><div class="contract-padding">${editing?'<div class="toolbar"><input id="contractFiles" type="file" multiple accept=".pdf,.doc,.docx,.xls,.xlsx,.jpg,.jpeg,.png" aria-label="选择合同附件"><button class="primary" id="uploadContractFiles">上传所选附件</button><span id="uploadProgress" role="status"></span></div>':''}${d.attachments.map(f=>`<div class="contract-file"><span>▤ ${esc(f.filename)} <small>(${(f.size_bytes/1024).toFixed(1)} KB)</small></span><a href="/api/contracts/${id}/attachments/${f.id}/download">下载附件</a>${editing?`<button data-remove-attachment="${f.id}">移除</button>`:''}</div>`).join('')||'<p class="helper">尚未上传附件，至少上传一份才能提交审核。</p>'}</div></div>
  <div class="panel"><div class="panel-head"><h3>操作记录</h3></div><div class="contract-price-wrap"><table><thead><tr><th>时间</th><th>操作</th><th>账户</th><th>说明</th></tr></thead><tbody>${d.events.map(e=>`<tr><td>${esc(contractTime(e.created_at))}</td><td>${esc(contractActions[e.action]||{create:'新建',edit:'修改表单',upload:'上传附件',remove_attachment:'移除附件'}[e.action]||e.action)}</td><td>${esc(e.actor_name)}</td><td>${esc(e.note)}</td></tr>`).join('')}</tbody></table></div></div>`;
  bind('backContracts','click',renderContracts);bind('editContract','click',()=>contractForm(d));
  $('page').querySelectorAll('[data-contract-action]').forEach(b=>b.onclick=()=>{
   const a=b.dataset.contractAction;
   modal(contractActions[a],`<p>合同：${esc(c.contract_no)}</p><label>操作说明${['reject','terminate'].includes(a)?'（必填）':''}<textarea id="contractActionNote" rows="3" maxlength="1000"></textarea></label>`,'<button id="cancelModal">取消</button><button class="primary" id="confirmContractAction">确认</button>');
   bind('confirmContractAction','click',run(async()=>{await api('/contracts/'+id+'/action',{method:'POST',body:JSON.stringify({action:a,version:c.version,note:$('contractActionNote').value})});closeModal();toast('操作完成');await viewContract(id)}));
  });
  $('page').querySelectorAll('[data-remove-attachment]').forEach(b=>b.onclick=()=>{
   modal('移除附件','<p>仅草稿和退回合同允许移除附件，操作会保留记录。</p>','<button id="cancelModal">取消</button><button class="primary" id="confirmRemoveAttachment">确认移除</button>');
   bind('confirmRemoveAttachment','click',run(async()=>{const r=await api(`/contracts/${id}/attachments/${b.dataset.removeAttachment}?version=${c.version}`,{method:'DELETE'});closeModal();toast(r.storage_cleaned?'附件已移除':'附件已移除，存储清理待管理员处理');await viewContract(id)}));
  });
  bind('uploadContractFiles','click',run(async()=>{
   const files=[...$('contractFiles').files];if(!files.length)throw Error('请先选择附件');
   if(files.length+d.attachments.length>20)throw Error('每份合同最多上传 20 个附件');
   if(files.some(f=>f.size>3*1024*1024||!f.size))throw Error('单个附件须为 1 字节至 3 MB');
   let version=c.version,done=0;
   try{
    for(const file of files){$('uploadProgress').textContent=`正在上传 ${done+1}/${files.length}：${file.name}`;const r=await api(`/contracts/${id}/attachments?filename=${encodeURIComponent(file.name)}&version=${version}`,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:file});version=r.version;done++}
    toast(`已上传 ${done} 个附件`);
   }catch(e){toast(`已上传 ${done} 个附件；${e.message}`,true)}
   await viewContract(id);
  }));
 }catch(e){$('page').innerHTML=`<div class="panel empty error">${esc(e.message)}</div>`}
}
