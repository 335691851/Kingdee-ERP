"""Grant an existing Supabase Auth subject ERP permissions through a trusted DB connection."""
import sys,argparse
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sqlalchemy import select
from app.db import engine
from app import schema as s
p=argparse.ArgumentParser()
p.add_argument('--subject',required=True,help='Existing Supabase Auth user UUID')
p.add_argument('--name',required=True)
p.add_argument('--companies',required=True,help='Comma-separated legal entity IDs')
p.add_argument('--role',choices=['viewer','operator','accountant','admin'],default='viewer')
a=p.parse_args();ids=sorted(set(int(x) for x in a.companies.split(',')))
with engine.begin() as c:
    if len(list(c.execute(select(s.company.c.id).where(s.company.c.id.in_(ids)))))!=len(ids):raise SystemExit('Unknown company ID')
    uid=c.execute(select(s.app_user.c.id).where(s.app_user.c.subject==a.subject)).scalar()
    if not uid:uid=c.execute(s.app_user.insert().values(subject=a.subject,name=a.name,enabled=True)).inserted_primary_key[0]
    for cid in ids:
        mid=c.execute(select(s.membership.c.id).where(s.membership.c.user_id==uid,s.membership.c.company_id==cid)).scalar()
        if mid:c.execute(s.membership.update().where(s.membership.c.id==mid).values(role=a.role))
        else:c.execute(s.membership.insert().values(user_id=uid,company_id=cid,role=a.role))
print('ERP company permissions saved. No Auth account was created.')
