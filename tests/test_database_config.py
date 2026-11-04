from sqlalchemy.engine import make_url
from app.config import normalize_database_url

def test_pooler_first_parameter_typo_keeps_encoded_password():
    raw='postgresql://postgres.vyulbopmxltjnptuqmcp:example%40a%26b@aws-0-us-east-2.pooler.supabase.com:6543/postgres&sslmode=require'
    result=make_url(normalize_database_url(raw))
    assert result.database=='postgres'
    assert result.query['sslmode']=='require'
    assert result.password=='example@a&b'
    assert result.port==6543

def test_valid_and_other_database_urls_are_preserved():
    raw='postgresql+psycopg://postgres.example:sample@aws-0-us-east-2.pooler.supabase.com:6543/postgres?sslmode=verify-full'
    assert normalize_database_url(raw)==raw
    other=raw.replace('postgres?sslmode=verify-full','other&sslmode=require')
    assert normalize_database_url(other)==other
    assert normalize_database_url('sqlite:///./work/erp.db')=='sqlite:///./work/erp.db'
