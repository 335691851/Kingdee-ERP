import pytest
from scripts.cloud_bootstrap import validate_database_target

REF='vyulbopmxltjnptuqmcp'

def test_transaction_pooler_encoded_password():
    validate_database_target(f'postgresql://postgres.{REF}:example%40password@aws-1-us-east-2.pooler.supabase.com:6543/postgres?sslmode=require',REF)

def test_malformed_connection_error_does_not_disclose_value():
    with pytest.raises(RuntimeError) as error:
        validate_database_target(f'postgresql://postgres:private-value@[db.{REF}.supabase.co]:5432/postgres',REF)
    assert 'private-value' not in str(error.value)
    assert 'format is invalid' in str(error.value)

def test_wrong_project_refuses_initialization():
    with pytest.raises(RuntimeError,match='does not match'):
        validate_database_target('postgresql://postgres.other:example@aws-1-us-east-2.pooler.supabase.com:6543/postgres',REF)
