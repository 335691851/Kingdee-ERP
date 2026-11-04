"""Export reviewable PostgreSQL DDL and a Mermaid ER diagram from the actual model."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sqlalchemy.schema import CreateTable,CreateIndex
from sqlalchemy.dialects import postgresql
from app.schema import M
root=Path(__file__).resolve().parents[1]
dialect=postgresql.dialect()
sql=['-- Run once in an empty Supabase public schema. See README.md.','BEGIN;']
er=['erDiagram']
dictionary=['# 数据字典（从实际代码生成）','','金额统一为人民币分；数量为六位小数。历史交易均为模拟数据。','']
for t in M.sorted_tables:
    sql.append(str(CreateTable(t).compile(dialect=dialect))+';')
    sql.extend(str(CreateIndex(i).compile(dialect=dialect))+';' for i in sorted(t.indexes,key=lambda i:i.name))
    sql.extend([f'ALTER TABLE public."{t.name}" ENABLE ROW LEVEL SECURITY;',f'REVOKE ALL ON TABLE public."{t.name}" FROM anon, authenticated;'])
    er.append(f'    {t.name} {{')
    dictionary.extend([f'## {t.name}','','| 字段 | 类型 | 可空 | 约束 |','|---|---|---|---|'])
    for col in t.c:
        typ=str(col.type).replace(' ','_').replace(',','_').replace('(','_').replace(')','')
        tag=' PK' if col.primary_key else ' FK' if col.foreign_keys else ''
        er.append(f'        {typ} {col.name}{tag}')
        refs=', '.join(f.target_fullname for f in col.foreign_keys)
        dictionary.append(f'| {col.name} | {col.type} | {"是" if col.nullable else "否"} | {"PK " if col.primary_key else ""}{refs} |')
    er.append('    }');dictionary.append('')
for t in M.sorted_tables:
    for fk in sorted(t.foreign_keys,key=lambda f:f.parent.name):
        er.append(f'    {fk.column.table.name} ||--o{{ {t.name} : "{fk.parent.name}"')
sql.extend(['REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;','COMMIT;'])
(root/'supabase/schema.sql').write_text('\n'.join(line.rstrip() for line in '\n\n'.join(sql).splitlines())+'\n',encoding='utf8')
(root/'docs/ER.mmd').write_text('\n'.join(er),encoding='utf8')
(root/'docs/数据字典.md').write_text('\n'.join(dictionary),encoding='utf8')
print(f'Exported {len(M.tables)} tables, indexes, RLS, ER, and dictionary.')
