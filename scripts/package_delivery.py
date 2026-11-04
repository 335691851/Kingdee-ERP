"""Package source separately from a consistent SQLite demo snapshot."""
import sqlite3,zipfile,json,hashlib
from contextlib import closing
from pathlib import Path
root=Path(__file__).resolve().parents[1];out=root/'outputs';out.mkdir(exist_ok=True)
source=out/'luyan-erp-source.zip';data=out/'luyan-erp-demo-data.zip'
excluded={'.venv','.git','.pytest_cache','__pycache__','work','outputs','.vercel'}
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted(root.rglob('*')):
        rel=p.relative_to(root)
        if p.is_file() and not any(part in excluded for part in rel.parts) and p.name!='.env.local':
            z.write(p,rel.as_posix())
    for name in ['data-validation.json','验收说明.md','test-results.xml','销售订单.png','产品成本.png','产品利润.png','物料主数据.png','分类利润核对.png']:
        p=out/name
        if p.exists():z.write(p,'outputs/'+name)
snapshot=root/'work/delivery-snapshot.db'
with closing(sqlite3.connect(root/'work/erp.db')) as src,closing(sqlite3.connect(snapshot)) as dst:src.backup(dst)
with zipfile.ZipFile(data,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    z.write(snapshot,'work/erp.db');z.write(out/'data-validation.json','outputs/data-validation.json')
snapshot.unlink()
files=[]
for p in [source,data]:
    sha=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):sha.update(chunk)
    files.append(dict(file=p.name,bytes=p.stat().st_size,sha256=sha.hexdigest()))
(out/'delivery-manifest.json').write_text(json.dumps(files,indent=2),encoding='utf8')
print(json.dumps(files,indent=2))
