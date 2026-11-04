"""Opt-in, production-build database setup. No public initialization HTTP endpoint."""
import json,os,sys
from pathlib import Path
from urllib.parse import unquote,urlsplit
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))

def main():
    if os.getenv('ERP_INITIALIZE_DATABASE')!='1':
        print('ERP database initialization disabled; no data written.')
        return
    if os.getenv('VERCEL_ENV')!='production':
        raise RuntimeError('Initialization is permitted only in the production build environment.')
    ref=os.getenv('ERP_BOOTSTRAP_PROJECT_REF','')
    target=urlsplit(os.getenv('DATABASE_URL',''))
    if not ref or (ref not in (target.hostname or '') and ref not in unquote(target.username or '')):
        raise RuntimeError('Database target does not match ERP_BOOTSTRAP_PROJECT_REF.')
    from sqlalchemy import select,func,inspect
    from app.db import engine
    from app import schema as s
    if engine.dialect.name!='postgresql':raise RuntimeError('Cloud setup requires PostgreSQL.')
    if not all(inspect(engine).has_table(t) for t in s.M.tables):
        raise RuntimeError('Apply the reviewed ERP schema migration before initializing history.')
    with engine.connect() as conn:
        complete=conn.execute(select(s.seed_run.c.id).where(s.seed_run.c.seed_key=='luyan-linked-history-v2-taxonomy')).scalar()
        count=conn.execute(select(func.count()).select_from(s.document)).scalar()
    if complete:
        print('Completed simulation seed found; preserving existing data.')
    elif count:
        raise RuntimeError('Database has existing documents without a completed seed; refusing to overwrite data.')
    else:
        from scripts.seed import seed
        seed(10000)
    from scripts.validate_data import validate
    result=validate()
    Path('outputs').mkdir(exist_ok=True)
    Path('outputs/cloud-validation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
    print('ERP_CLOUD_VALIDATION '+json.dumps(dict(passed=result['passed'],documents=result['table_counts']['document'],checks=result['violations']),ensure_ascii=False))
    if not result['passed']:raise RuntimeError('Cloud history integrity validation failed.')
    print('ERP cloud initialization complete; disable ERP_INITIALIZE_DATABASE after this build.')

if __name__=='__main__':main()
