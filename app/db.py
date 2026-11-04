import os
from pathlib import Path
from dotenv import load_dotenv
from sqlalchemy import create_engine,event
from sqlalchemy.pool import NullPool
from .config import normalize_database_url
load_dotenv('.env.local')
URL=normalize_database_url(os.getenv('DATABASE_URL','sqlite:///./work/erp.db'))
PRODUCTION=bool(os.getenv('VERCEL')) or os.getenv('AUTH_MODE')=='supabase'
if PRODUCTION and not URL.startswith('postgresql+psycopg://'):
    raise RuntimeError('Production requires Supabase PostgreSQL DATABASE_URL; SQLite is local-only.')
if URL.startswith('sqlite:'):
    Path('work').mkdir(exist_ok=True)
    engine=create_engine(URL,connect_args={'check_same_thread':False,'timeout':60})
    @event.listens_for(engine,'connect')
    def sqlite_settings(conn,_):
        conn.execute('PRAGMA foreign_keys=ON'); conn.execute('PRAGMA journal_mode=WAL')
else:
    # Supavisor transaction-pooler URL. Prepared statements must be disabled.
    engine=create_engine(URL,poolclass=NullPool,connect_args={'prepare_threshold':None,'connect_timeout':15})
