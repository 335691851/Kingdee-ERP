"""Explicit operator command: create/validate a private contract bucket. Never run on build."""
import os,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from dotenv import load_dotenv
import httpx
from app.contract_storage import MIME,MAX_FILE_BYTES

def main():
    load_dotenv('.env.local')
    url=os.getenv('SUPABASE_URL','').rstrip('/')
    key=os.getenv('SUPABASE_SECRET_KEY','')
    bucket=os.getenv('CONTRACT_STORAGE_BUCKET','erp-contracts')
    if not url.startswith('https://') or not key:raise SystemExit('Set SUPABASE_URL and server-only SUPABASE_SECRET_KEY first.')
    if bucket!='erp-contracts':raise SystemExit('This setup command only provisions the reviewed erp-contracts bucket.')
    with httpx.Client(base_url=url+'/storage/v1',headers={'apikey':key,'Authorization':'Bearer '+key},timeout=30) as client:
        r=client.get('/bucket/'+bucket)
        if r.status_code==404:
            r=client.post('/bucket',json=dict(id=bucket,name=bucket,public=False,file_size_limit=MAX_FILE_BYTES,allowed_mime_types=sorted(set(MIME.values()))))
            if not r.is_success:raise SystemExit(f'Bucket creation failed (HTTP {r.status_code}); check the project and secret key.')
            print('Created private erp-contracts bucket; file limit 3 MB.')
        elif r.is_success:
            if r.json().get('public') is not False:raise SystemExit('Existing bucket is public; refusing to use it for contracts. Review its access settings first.')
            print('Existing private erp-contracts bucket verified. No bucket settings changed.')
        else:raise SystemExit(f'Bucket lookup failed (HTTP {r.status_code}); no settings changed.')

if __name__=='__main__':
    try:main()
    except httpx.HTTPError:raise SystemExit('Storage connection failed. No credentials printed; check network and project configuration.') from None
