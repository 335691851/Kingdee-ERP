import os,secrets,hmac
from datetime import datetime,timedelta,timezone
import httpx,jwt
from fastapi import Depends,HTTPException,Request
from sqlalchemy import select
from .db import engine,PRODUCTION
from . import schema as s
AUTH_MODE=os.getenv('AUTH_MODE','demo')
SECRET=os.getenv('SESSION_SECRET') or (secrets.token_urlsafe(48) if not PRODUCTION else '')
if PRODUCTION and AUTH_MODE!='supabase': raise RuntimeError('Production AUTH_MODE must be supabase')
def token_for_demo(username,password):
    if AUTH_MODE!='demo' or PRODUCTION: raise HTTPException(400,'当前部署使用 Supabase 登录')
    if not (hmac.compare_digest(username,os.getenv('DEMO_USERNAME','admin')) and hmac.compare_digest(password,os.getenv('DEMO_PASSWORD','luyan-demo-2026'))):
        raise HTTPException(401,'用户名或密码错误')
    return jwt.encode({'sub':'demo-admin','exp':datetime.now(timezone.utc)+timedelta(hours=8)},SECRET,algorithm='HS256')
def current_user(request:Request):
    token=request.cookies.get('erp_session')
    auth=request.headers.get('Authorization','')
    if auth.startswith('Bearer '): token=auth[7:]
    if not token: raise HTTPException(401,'请先登录')
    if AUTH_MODE=='demo' and not PRODUCTION:
        try: subject=jwt.decode(token,SECRET,algorithms=['HS256'])['sub']
        except jwt.PyJWTError: raise HTTPException(401,'登录已过期')
    else:
        url=os.getenv('SUPABASE_URL','').rstrip('/')
        key=os.getenv('SUPABASE_PUBLISHABLE_KEY','')
        if not url or not key: raise HTTPException(503,'尚未配置 Supabase Auth')
        try:
            r=httpx.get(url+'/auth/v1/user',headers={'apikey':key,'Authorization':'Bearer '+token},timeout=12)
            if r.status_code!=200: raise HTTPException(401,'登录已过期，请重新登录')
            subject=r.json()['id']
        except httpx.HTTPError: raise HTTPException(503,'登录服务暂不可用')
    with engine.connect() as conn:
        user=conn.execute(select(s.app_user).where(s.app_user.c.subject==subject,s.app_user.c.enabled==True)).mappings().first()
        if not user: raise HTTPException(403,'此账户尚未分配 ERP 权限')
        grants={r.company_id:r.role for r in conn.execute(select(s.membership).where(s.membership.c.user_id==user['id']))}
    return dict(user,grants=grants)
def authorize(user,company_id=None,write=False,finance=False):
    ids=list(user['grants'])
    if company_id is not None and company_id not in ids: raise HTTPException(403,'无权访问该独立法人')
    if company_id is not None:
        role=user['grants'][company_id]
        if write and role=='viewer': raise HTTPException(403,'只读角色不能修改数据')
        if finance and role not in ('accountant','admin'): raise HTTPException(403,'需要财务或管理员权限')
    return ids if company_id is None else [company_id]
