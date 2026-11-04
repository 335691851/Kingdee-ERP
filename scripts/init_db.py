"""Initialize an empty database; never called by a web request."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sqlalchemy import text
from app.db import engine
from app.schema import M

def initialize():
    M.create_all(engine)
    if engine.dialect.name=='postgresql':
        with engine.begin() as conn:
            for table in M.sorted_tables:
                conn.execute(text(f'ALTER TABLE public."{table.name}" ENABLE ROW LEVEL SECURITY'))
                conn.execute(text(f'REVOKE ALL ON TABLE public."{table.name}" FROM anon, authenticated'))
            conn.execute(text('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated'))
    print(f'Initialized {len(M.tables)} tables. Browser roles have no direct table access.')
if __name__=='__main__':initialize()
