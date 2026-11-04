from app.auth import login_email

def test_admin_alias_uses_configured_email_only(monkeypatch):
    monkeypatch.setenv('ERP_ADMIN_EMAIL',' admin@example.com ')
    assert login_email(' admin ')=='admin@example.com'
    assert login_email('someone@example.com')=='someone@example.com'
    assert login_email('another')=='another'
    monkeypatch.delenv('ERP_ADMIN_EMAIL')
    assert login_email('admin')=='admin'
