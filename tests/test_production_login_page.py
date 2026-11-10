from app import main

def test_production_login_prefills_requested_account(monkeypatch):
    monkeypatch.setattr(main,'PRODUCTION',True)
    body=main.index().body.decode('utf8')
    assert 'id="username" value="admin@luyin.com"' in body
    assert 'id="password" value="admin"' in body
    assert 'luyan-demo-2026' not in body
    assert 'placeholder="Supabase 登录邮箱"' in body
    assert '已开通 ERP 法人权限' in body
