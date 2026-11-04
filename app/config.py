"""Connection configuration normalization; never log credential values."""
from sqlalchemy.engine import make_url

def normalize_database_url(value):
    if value.startswith('postgres://'):
        value=value.replace('postgres://','postgresql+psycopg://',1)
    elif value.startswith('postgresql://'):
        value=value.replace('postgresql://','postgresql+psycopg://',1)
    if value.startswith('postgresql+psycopg://'):
        parsed=make_url(value)
        # A copied pooler URL may append the first query parameter with '&'.
        # Limit correction to this exact observed typo; don't rewrite passwords.
        if (parsed.host or '').endswith('.pooler.supabase.com') and parsed.database=='postgres&sslmode=require' and not parsed.query:
            return parsed.set(database='postgres',query={'sslmode':'require'}).render_as_string(hide_password=False)
    return value
