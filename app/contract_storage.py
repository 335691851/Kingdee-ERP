"""Private attachment storage. No uploaded file is served from /assets."""
import os
from pathlib import Path
from urllib.parse import quote
import httpx
from fastapi import HTTPException
from .db import PRODUCTION

MAX_FILE_BYTES = 3 * 1024 * 1024
MIME = {'.pdf':'application/pdf','.docx':'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        '.xlsx':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        '.doc':'application/msword','.xls':'application/vnd.ms-excel','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg'}

def validate_file(filename, data):
    if not filename or len(filename)>180 or any(ch in filename for ch in '/\\\r\n\x00'):
        raise HTTPException(422,'附件名称无效，最多 180 字，不能包含路径或换行')
    ext=Path(filename).suffix.lower()
    if ext not in MIME:raise HTTPException(422,'支持 PDF、Word、Excel、JPG 和 PNG 文件')
    if not data or len(data)>MAX_FILE_BYTES:raise HTTPException(413,'单个附件须为 1 字节至 3 MB')
    signatures={'.pdf':b'%PDF-','.doc':b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1','.xls':b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1',
                '.png':b'\x89PNG\r\n\x1a\n','.jpg':b'\xff\xd8\xff','.jpeg':b'\xff\xd8\xff'}
    if ext in ('.docx','.xlsx'):
        import io,zipfile
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                names=set(z.namelist())
                valid='[Content_Types].xml' in names and ('word/document.xml' if ext=='.docx' else 'xl/workbook.xml') in names
        except (zipfile.BadZipFile,ValueError):valid=False
    else:valid=data.startswith(signatures[ext])
    if not valid:raise HTTPException(422,'文件内容与扩展名不匹配')
    return MIME[ext]

def config():
    mode=os.getenv('CONTRACT_STORAGE_BACKEND','supabase' if PRODUCTION else 'local')
    if mode=='local' and not PRODUCTION:return mode,None,None,None
    if mode!='supabase':raise HTTPException(503,'线上合同附件必须配置私有对象存储')
    url=os.getenv('SUPABASE_URL','').rstrip('/')
    key=os.getenv('SUPABASE_SECRET_KEY','')
    bucket=os.getenv('CONTRACT_STORAGE_BUCKET','erp-contracts')
    if not url or not key:raise HTTPException(503,'合同附件存储尚未配置，请联系管理员')
    return mode,url,key,bucket

def local_path(object_key):
    root=Path(os.getenv('CONTRACT_LOCAL_DIR','work/contract-files')).resolve()
    path=(root/object_key).resolve()
    if root not in path.parents:raise HTTPException(400,'无效附件路径')
    return path

def storage_request(method,path,**kwargs):
    _,url,key,_=config()
    try:
        r=httpx.request(method,url+'/storage/v1'+path,headers={'apikey':key,'Authorization':'Bearer '+key,**kwargs.pop('headers',{})},timeout=30,**kwargs)
    except httpx.HTTPError:raise HTTPException(503,'附件存储暂不可用，请稍后重试') from None
    if not r.is_success:raise HTTPException(503,'附件存储操作失败，请检查私有桶和服务端密钥配置')
    return r

def put(object_key,data,content_type):
    mode,_,_,bucket=config()
    if mode=='local':
        path=local_path(object_key);path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('xb') as f:f.write(data)
    else:storage_request('POST','/object/'+quote(bucket,safe='')+'/'+quote(object_key,safe='/'),content=data,headers={'Content-Type':content_type,'x-upsert':'false'})

def remove(object_key):
    mode,_,_,bucket=config()
    if mode=='local':local_path(object_key).unlink(missing_ok=True)
    else:storage_request('DELETE','/object/'+quote(bucket,safe=''),json={'prefixes':[object_key]})

def signed_url(object_key,filename):
    _,url,_,bucket=config()
    r=storage_request('POST','/object/sign/'+quote(bucket,safe='')+'/'+quote(object_key,safe='/'),json={'expiresIn':60})
    signed=r.json().get('signedURL','')
    # Accept only the expected relative Storage API path; never redirect to an arbitrary host.
    if not signed.startswith('/object/sign/'):raise HTTPException(503,'附件下载链接生成失败')
    return url+'/storage/v1'+signed+'&download='+quote(filename,safe='')
