# 鲁盐集团小型 ERP

Python 3.12 + FastAPI + SQLAlchemy。前端为原生 JavaScript/CSS，由同一应用提供；部署目标为 Vercel + Supabase PostgreSQL/Auth。此交付只包含代码和本地模拟数据，没有写入现有云项目。

## 数据性质与范围

业务单据是 **2024-01-01 至 2026-10-26 的关联模拟历史**，不是鲁盐集团真实交易。截图用于字段、名称和界面参考；本系统是自主设计，不是金蝶官方源代码、数据库复刻或认证产品。页面持续标识“模拟”。

覆盖销售、采购、合同、批次库存、生产 BOM/领料/报工/完工、实际成本、应收应付、资金核销、总账凭证、法人权限、基础资料及产品利润。43 张关系表，20 类单据各至少 10,000 条，合计 300,000 张单据。组织与名称出处见 [业务与计算口径](docs/业务与计算口径.md)。

## 本地运行（Windows PowerShell）

在项目根目录执行：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env.local
# 如已有交付的 work/erp.db，不必再次播种。
.\.venv\Scripts\python.exe scripts/seed.py --cycles 10000
.\.venv\Scripts\python.exe scripts/validate_data.py
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8765
```

打开 http://127.0.0.1:8765 。本地账户 `admin`，密码 `luyan-demo-2026`。开发接口文档为 `/api/docs`。若使用数据包，将其中的 `work/erp.db` 解压到项目根目录即可；SQLite 仅用于本地演示，不能作为 Vercel 持久数据库。

数据库已有业务数据时，生成器拒绝再次写入。中断的生成任务需使用另一个空演示数据库重新生成；不要在已有业务库上重复执行。小规模开发可设置 `DATABASE_URL=sqlite:///./work/dev.db` 后运行 `--cycles 20`，但这不满足万行验收。

## 部署到 Supabase + Vercel

1. 为本 ERP 准备一个独立、空的 Supabase 项目或数据库。先在本地设置指向该项目的 `DATABASE_URL`，采用控制台提供的 **transaction pooler** 连接字符串（通常端口 6543），保留用户名中的项目标识，连接参数加 `sslmode=require`；密码中保留字符需 URL 编码。凭据只存服务端。
2. 在可信本地终端执行 `python scripts/init_db.py`，再执行 `python scripts/seed.py --cycles 10000`。它们不会在网页启动时执行。也可先在空库的 SQL Editor 执行 [schema.sql](supabase/schema.sql)，再播种。两种建表方式择一；已有表用初始化脚本，不能重复执行 SQL DDL。生成与导入可能耗时数分钟，需提前确认数据库容量。完整本地数据库约 217 MiB，云端含索引大小以实际为准。
3. 初始化会对全部 ERP 表启用 RLS，并撤销 `anon`、`authenticated` 的表和序列权限。浏览器只调用 FastAPI；不直接使用 Supabase Data API 读写这些表。后端使用可访问 ERP 表的可信数据库角色，逐次校验用户与法人权限。默认连接所有者可绕过 RLS，因此后端权限检查必须保留。
4. 在 Supabase Auth 创建邮箱/密码账户。取得该账户的 User UUID，在可信终端执行：

```powershell
python scripts/grant_access.py --subject "用户UUID" --name "ERP管理员" --companies "1,2,3,4,5,6,7,8,9,10,11,12" --role admin
```

5. 将源码推送到自己的 Git 仓库，在 Vercel 导入，根目录选本目录。应用入口已在 `pyproject.toml` 指定为 `app.main:app`；不需要前端构建命令。使用 Python 3.12。设置生产/预览所需环境变量：

| 变量 | 值 |
|---|---|
| `DATABASE_URL` | Supabase PostgreSQL transaction pooler URL，带 `sslmode=require` |
| `AUTH_MODE` | `supabase` |
| `SUPABASE_URL` | `https://项目标识.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | 项目 publishable key（旧项目可用 anon key） |

6. 部署后先检查 `/api/health`，应返回 `database=postgresql`、`auth_mode=supabase`。然后用已授权邮箱登录，检查公司切换、列表、明细和成本报表。Vercel 环境强制 PostgreSQL 和 Supabase Auth，本地演示账户不会用于生产登录。无需配置 Supabase service-role key。会话到期后需重新登录，此版本未实现自动刷新。

代码已针对 PostgreSQL 生成 DDL 并配置连接池兼容；此次没有连接、初始化或验证云端实例，最终云端验证需在你配置目标项目之后进行。Vercel 配置与依赖参考官方文档：[FastAPI](https://vercel.com/docs/frameworks/backend/fastapi)、[Supabase 数据库连接](https://supabase.com/docs/guides/database/connecting-to-postgres)、[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)。

## 操作流程

- 新增单据 → 保存草稿 → 提交 → 审核 → 过账；审核后可“关联生成”下游草稿。下游单据继续独立提交、审核、过账。相同来源和目标类型阻止重复生成。
- 采购：需求申请 → 采购申请 → 采购订单 → 收货 → 入库 → 暂估应付 → 收票 → 财务应付 → 付款。采购合同可生成订单。
- 销售：合同 → 订单 → 发货通知 → 出库 → 开票 → 财务应收 → 收款。出库才扣库存，不能以订单金额代替销售成本。
- 生产：选择生产法人，新增单产品工单 → 审核 → 关联生成领料并过账 → 工单“生产报工” → 成本模块按同一法人/期间归集人工与制造费用 → 执行成本计算 → 工单“生成完工入库”并过账。先确保原料和包材库存足够；新工单须选有 BOM 的产品。
- 核销：在财务应收/应付单点击“收付款核销”，填写同法人、同往来方的已过账收/付款单 ID 与金额。支持部分核销，余额和并发重复核销由后端拦截。

## 验证与文档

```powershell
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe scripts/validate_data.py
.\.venv\Scripts\python.exe scripts/export_schema.py
```

测试使用独立的 `work/erp-tests.db`，不更改演示库。验收报告位于 `outputs/data-validation.json`；[ER 图源码](docs/ER.mmd)、[数据字典](docs/数据字典.md)、[业务口径与边界](docs/业务与计算口径.md) 可供后续扩展。

这是可运行的小型 ERP 演示基线。未实现电子发票对接、银行支付、法定报表、集团合并抵销、多币种重估、复杂跨期在制品与联副产品分配；报表和凭证规则需要财务人员按正式业务制度配置和复核后，才能用于实际经营。

## 物料分类升级

当前为两级分类版：27 项物料（13 项产销盐品、14 项原料与包材）。库存、成本和利润采用同一主数据；利润支持一级、二级、盐源、包装筛选。升级说明及旧库备份位置见 [物料分类升级说明](docs/物料分类升级说明.md)。旧结构数据库需与旧代码配套；新版本请使用新版数据包或在空库重新初始化。
