-- Run once in an empty Supabase public schema. See README.md.

BEGIN;


CREATE TABLE app_user (
	id SERIAL NOT NULL,
	subject VARCHAR(120) NOT NULL,
	name VARCHAR(120) NOT NULL,
	enabled BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (subject)
)

;

ALTER TABLE public."app_user" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."app_user" FROM anon, authenticated;


CREATE TABLE company (
	id SERIAL NOT NULL,
	code VARCHAR(120) NOT NULL,
	name VARCHAR(200) NOT NULL,
	kind VARCHAR(120) NOT NULL,
	legal_name_confirmed BOOLEAN NOT NULL,
	parent_id INTEGER,
	PRIMARY KEY (id),
	UNIQUE (code),
	FOREIGN KEY(parent_id) REFERENCES company (id)
)

;

ALTER TABLE public."company" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."company" FROM anon, authenticated;


CREATE TABLE currency (
	id SERIAL NOT NULL,
	code VARCHAR(120) NOT NULL,
	name VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (code)
)

;

ALTER TABLE public."currency" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."currency" FROM anon, authenticated;


CREATE TABLE document_type (
	id SERIAL NOT NULL,
	code VARCHAR(120) NOT NULL,
	label VARCHAR(120) NOT NULL,
	module VARCHAR(120) NOT NULL,
	prefix VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (code)
)

;

ALTER TABLE public."document_type" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."document_type" FROM anon, authenticated;


CREATE TABLE gl_account (
	id SERIAL NOT NULL,
	code VARCHAR(120) NOT NULL,
	name VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (code)
)

;

ALTER TABLE public."gl_account" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."gl_account" FROM anon, authenticated;


CREATE TABLE material_category (
	id SERIAL NOT NULL,
	name VARCHAR(120) NOT NULL,
	code VARCHAR(120) NOT NULL,
	parent_id INTEGER,
	level INTEGER NOT NULL,
	PRIMARY KEY (id),
	CHECK ((level=1 AND parent_id IS NULL) OR (level=2 AND parent_id IS NOT NULL)),
	UNIQUE (name),
	UNIQUE (code),
	FOREIGN KEY(parent_id) REFERENCES material_category (id)
)

;

CREATE INDEX ix_material_category_parent_id ON material_category (parent_id);

ALTER TABLE public."material_category" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."material_category" FROM anon, authenticated;


CREATE TABLE seed_run (
	id SERIAL NOT NULL,
	seed_key VARCHAR(120) NOT NULL,
	created_at VARCHAR(120) NOT NULL,
	cycles INTEGER NOT NULL,
	is_simulated BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (seed_key)
)

;

ALTER TABLE public."seed_run" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."seed_run" FROM anon, authenticated;


CREATE TABLE uom (
	id SERIAL NOT NULL,
	name VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (name)
)

;

ALTER TABLE public."uom" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."uom" FROM anon, authenticated;


CREATE TABLE bank_account (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	masked_account VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."bank_account" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."bank_account" FROM anon, authenticated;


CREATE TABLE cost_center (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."cost_center" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."cost_center" FROM anon, authenticated;


CREATE TABLE cost_rule (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	cost_item VARCHAR(120) NOT NULL,
	allocation_basis VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."cost_rule" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."cost_rule" FROM anon, authenticated;


CREATE TABLE department (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

CREATE INDEX ix_department_company_id ON department (company_id);

ALTER TABLE public."department" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."department" FROM anon, authenticated;


CREATE TABLE fiscal_period (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	period VARCHAR(7) NOT NULL,
	closed BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (company_id, period),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."fiscal_period" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."fiscal_period" FROM anon, authenticated;


CREATE TABLE ledger (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	currency_id INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (company_id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(currency_id) REFERENCES currency (id)
)

;

ALTER TABLE public."ledger" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."ledger" FROM anon, authenticated;


CREATE TABLE material (
	id SERIAL NOT NULL,
	code VARCHAR(120) NOT NULL,
	name VARCHAR(260) NOT NULL,
	spec VARCHAR(120) NOT NULL,
	category_id INTEGER NOT NULL,
	uom_id INTEGER NOT NULL,
	kind VARCHAR(120) NOT NULL,
	list_price_cents BIGINT NOT NULL,
	lot_managed BOOLEAN NOT NULL,
	salt_origin VARCHAR(16) NOT NULL,
	packaging VARCHAR(16) NOT NULL,
	product_feature VARCHAR(120) NOT NULL,
	classification_status VARCHAR(16) NOT NULL,
	source_note VARCHAR(300) NOT NULL,
	PRIMARY KEY (id),
	CHECK (salt_origin IN ('sea','mineral','unknown','na')),
	CHECK (packaging IN ('small','large','bulk','na')),
	CHECK (classification_status IN ('classified','pending')),
	UNIQUE (code),
	FOREIGN KEY(category_id) REFERENCES material_category (id),
	FOREIGN KEY(uom_id) REFERENCES uom (id)
)

;

CREATE INDEX ix_material_category_id ON material (category_id);

ALTER TABLE public."material" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."material" FROM anon, authenticated;


CREATE TABLE membership (
	id SERIAL NOT NULL,
	user_id INTEGER NOT NULL,
	company_id INTEGER NOT NULL,
	role VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (user_id, company_id),
	CHECK (role IN ('viewer','operator','accountant','admin')),
	FOREIGN KEY(user_id) REFERENCES app_user (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."membership" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."membership" FROM anon, authenticated;


CREATE TABLE organization (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	function VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

CREATE INDEX ix_organization_company_id ON organization (company_id);

ALTER TABLE public."organization" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."organization" FROM anon, authenticated;


CREATE TABLE partner (
	id SERIAL NOT NULL,
	code VARCHAR(120) NOT NULL,
	name VARCHAR(220) NOT NULL,
	kind VARCHAR(120) NOT NULL,
	related_company_id INTEGER,
	PRIMARY KEY (id),
	UNIQUE (code),
	FOREIGN KEY(related_company_id) REFERENCES company (id)
)

;

ALTER TABLE public."partner" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."partner" FROM anon, authenticated;


CREATE TABLE warehouse (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	kind VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

CREATE INDEX ix_warehouse_company_id ON warehouse (company_id);

ALTER TABLE public."warehouse" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."warehouse" FROM anon, authenticated;


CREATE TABLE bin_location (
	id SERIAL NOT NULL,
	warehouse_id INTEGER NOT NULL,
	code VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(warehouse_id) REFERENCES warehouse (id)
)

;

ALTER TABLE public."bin_location" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."bin_location" FROM anon, authenticated;


CREATE TABLE bom (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	version VARCHAR(120) NOT NULL,
	yield_rate NUMERIC(8, 6) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(material_id) REFERENCES material (id)
)

;

ALTER TABLE public."bom" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."bom" FROM anon, authenticated;


CREATE TABLE cost_pool (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	period VARCHAR(7) NOT NULL,
	center_id INTEGER NOT NULL,
	item VARCHAR(120) NOT NULL,
	amount_cents BIGINT NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(center_id) REFERENCES cost_center (id)
)

;

CREATE INDEX ix_cost_pool_company_id ON cost_pool (company_id);

ALTER TABLE public."cost_pool" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."cost_pool" FROM anon, authenticated;


CREATE TABLE employee (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	department_id INTEGER NOT NULL,
	name VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(department_id) REFERENCES department (id)
)

;

CREATE INDEX ix_employee_company_id ON employee (company_id);

ALTER TABLE public."employee" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."employee" FROM anon, authenticated;


CREATE TABLE lot (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	lot_no VARCHAR(120) NOT NULL,
	manufactured_on VARCHAR(10) NOT NULL,
	expires_on VARCHAR(10) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (company_id, material_id, lot_no),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(material_id) REFERENCES material (id)
)

;

ALTER TABLE public."lot" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."lot" FROM anon, authenticated;


CREATE TABLE material_org (
	id SERIAL NOT NULL,
	material_id INTEGER NOT NULL,
	company_id INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (material_id, company_id),
	FOREIGN KEY(material_id) REFERENCES material (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."material_org" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."material_org" FROM anon, authenticated;


CREATE TABLE partner_role (
	id SERIAL NOT NULL,
	partner_id INTEGER NOT NULL,
	company_id INTEGER NOT NULL,
	role VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (partner_id, company_id, role),
	FOREIGN KEY(partner_id) REFERENCES partner (id),
	FOREIGN KEY(company_id) REFERENCES company (id)
)

;

ALTER TABLE public."partner_role" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."partner_role" FROM anon, authenticated;


CREATE TABLE bom_line (
	id SERIAL NOT NULL,
	bom_id INTEGER NOT NULL,
	component_id INTEGER NOT NULL,
	qty_per_ton NUMERIC(24, 6) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(bom_id) REFERENCES bom (id),
	FOREIGN KEY(component_id) REFERENCES material (id)
)

;

ALTER TABLE public."bom_line" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."bom_line" FROM anon, authenticated;


CREATE TABLE document (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	type_code VARCHAR(40) NOT NULL,
	bill_no VARCHAR(100) NOT NULL,
	bill_date VARCHAR(10) NOT NULL,
	status VARCHAR(20) NOT NULL,
	partner_id INTEGER,
	employee_id INTEGER,
	warehouse_id INTEGER,
	currency_id INTEGER NOT NULL,
	net_cents BIGINT NOT NULL,
	tax_cents BIGINT NOT NULL,
	total_cents BIGINT NOT NULL,
	settled_cents BIGINT NOT NULL,
	freight_cents BIGINT NOT NULL,
	version INTEGER NOT NULL,
	is_simulated BOOLEAN NOT NULL,
	memo TEXT NOT NULL,
	created_at VARCHAR(120) NOT NULL,
	updated_at VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	CHECK (total_cents = net_cents + tax_cents),
	CHECK (net_cents >= 0 AND tax_cents >= 0 AND settled_cents >= 0 AND settled_cents <= total_cents),
	CHECK (status IN ('draft','submitted','approved','posted','closed')),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(type_code) REFERENCES document_type (code),
	UNIQUE (bill_no),
	FOREIGN KEY(partner_id) REFERENCES partner (id),
	FOREIGN KEY(employee_id) REFERENCES employee (id),
	FOREIGN KEY(warehouse_id) REFERENCES warehouse (id),
	FOREIGN KEY(currency_id) REFERENCES currency (id)
)

;

CREATE INDEX ix_document_company_type_date ON document (company_id, type_code, bill_date, id);

CREATE INDEX ix_document_type_date ON document (type_code, bill_date);

ALTER TABLE public."document" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."document" FROM anon, authenticated;


CREATE TABLE sales_contract (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	organization_id INTEGER NOT NULL,
	contract_no VARCHAR(80) NOT NULL,
	title VARCHAR(200) NOT NULL,
	kind VARCHAR(20) NOT NULL,
	salesperson_id INTEGER NOT NULL,
	owner_id INTEGER NOT NULL,
	signed_on VARCHAR(10) NOT NULL,
	valid_from VARCHAR(10) NOT NULL,
	valid_to VARCHAR(10) NOT NULL,
	payment_terms VARCHAR(500) NOT NULL,
	service_terms TEXT NOT NULL,
	notes TEXT NOT NULL,
	status VARCHAR(20) NOT NULL,
	version INTEGER NOT NULL,
	created_at VARCHAR(120) NOT NULL,
	updated_at VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (company_id, contract_no),
	CHECK (kind IN ('goods','service','mixed')),
	CHECK (status IN ('draft','submitted','approved','rejected','terminated')),
	CHECK (valid_to >= valid_from),
	CHECK (version > 0),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(organization_id) REFERENCES organization (id),
	FOREIGN KEY(salesperson_id) REFERENCES employee (id),
	FOREIGN KEY(owner_id) REFERENCES app_user (id)
)

;

CREATE INDEX ix_sales_contract_company_id ON sales_contract (company_id);

ALTER TABLE public."sales_contract" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."sales_contract" FROM anon, authenticated;


CREATE TABLE stock_balance (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	warehouse_id INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	lot_id INTEGER NOT NULL,
	qty NUMERIC(24, 6) NOT NULL,
	reserved_qty NUMERIC(24, 6) NOT NULL,
	cost_cents BIGINT NOT NULL,
	version INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (company_id, warehouse_id, material_id, lot_id),
	CHECK (qty >= 0 AND reserved_qty >= 0 AND reserved_qty <= qty),
	CHECK (cost_cents >= 0),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(warehouse_id) REFERENCES warehouse (id),
	FOREIGN KEY(material_id) REFERENCES material (id),
	FOREIGN KEY(lot_id) REFERENCES lot (id)
)

;

ALTER TABLE public."stock_balance" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."stock_balance" FROM anon, authenticated;


CREATE TABLE audit_event (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	document_id INTEGER,
	actor VARCHAR(120) NOT NULL,
	action VARCHAR(120) NOT NULL,
	before_state TEXT NOT NULL,
	after_state TEXT NOT NULL,
	created_at VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(document_id) REFERENCES document (id)
)

;

CREATE INDEX ix_audit_event_document_id ON audit_event (document_id);

ALTER TABLE public."audit_event" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."audit_event" FROM anon, authenticated;


CREATE TABLE contract_attachment (
	id SERIAL NOT NULL,
	contract_id INTEGER NOT NULL,
	object_key VARCHAR(300) NOT NULL,
	filename VARCHAR(180) NOT NULL,
	content_type VARCHAR(120) NOT NULL,
	size_bytes INTEGER NOT NULL,
	sha256 VARCHAR(64) NOT NULL,
	uploaded_by INTEGER NOT NULL,
	created_at VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(contract_id) REFERENCES sales_contract (id),
	UNIQUE (object_key),
	FOREIGN KEY(uploaded_by) REFERENCES app_user (id)
)

;

CREATE INDEX ix_contract_attachment_contract_id ON contract_attachment (contract_id);

ALTER TABLE public."contract_attachment" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."contract_attachment" FROM anon, authenticated;


CREATE TABLE contract_category (
	id SERIAL NOT NULL,
	contract_id INTEGER NOT NULL,
	category_id INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (contract_id, category_id),
	FOREIGN KEY(contract_id) REFERENCES sales_contract (id),
	FOREIGN KEY(category_id) REFERENCES material_category (id)
)

;

CREATE INDEX ix_contract_category_contract_id ON contract_category (contract_id);

ALTER TABLE public."contract_category" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."contract_category" FROM anon, authenticated;


CREATE TABLE contract_customer (
	id SERIAL NOT NULL,
	contract_id INTEGER NOT NULL,
	partner_id INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (contract_id, partner_id),
	FOREIGN KEY(contract_id) REFERENCES sales_contract (id),
	FOREIGN KEY(partner_id) REFERENCES partner (id)
)

;

CREATE INDEX ix_contract_customer_contract_id ON contract_customer (contract_id);

ALTER TABLE public."contract_customer" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."contract_customer" FROM anon, authenticated;


CREATE TABLE contract_event (
	id SERIAL NOT NULL,
	contract_id INTEGER NOT NULL,
	actor_id INTEGER NOT NULL,
	action VARCHAR(120) NOT NULL,
	note VARCHAR(1000) NOT NULL,
	created_at VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(contract_id) REFERENCES sales_contract (id),
	FOREIGN KEY(actor_id) REFERENCES app_user (id)
)

;

CREATE INDEX ix_contract_event_contract_id ON contract_event (contract_id);

ALTER TABLE public."contract_event" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."contract_event" FROM anon, authenticated;


CREATE TABLE contract_price (
	id SERIAL NOT NULL,
	contract_id INTEGER NOT NULL,
	line_no INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	unit_price_cents BIGINT NOT NULL,
	min_qty NUMERIC(24, 6) NOT NULL,
	max_qty NUMERIC(24, 6),
	tax_rate NUMERIC(8, 6) NOT NULL,
	includes_tax BOOLEAN NOT NULL,
	remark VARCHAR(500) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (contract_id, line_no),
	CHECK (unit_price_cents >= 0 AND min_qty >= 0),
	CHECK (max_qty IS NULL OR max_qty >= min_qty),
	CHECK (tax_rate >= 0 AND tax_rate <= 1),
	FOREIGN KEY(contract_id) REFERENCES sales_contract (id),
	FOREIGN KEY(material_id) REFERENCES material (id)
)

;

CREATE INDEX ix_contract_price_contract_id ON contract_price (contract_id);

ALTER TABLE public."contract_price" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."contract_price" FROM anon, authenticated;


CREATE TABLE contract_sku (
	id SERIAL NOT NULL,
	contract_id INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (contract_id, material_id),
	FOREIGN KEY(contract_id) REFERENCES sales_contract (id),
	FOREIGN KEY(material_id) REFERENCES material (id)
)

;

CREATE INDEX ix_contract_sku_contract_id ON contract_sku (contract_id);

ALTER TABLE public."contract_sku" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."contract_sku" FROM anon, authenticated;


CREATE TABLE cost_calculation (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	production_id INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	period VARCHAR(7) NOT NULL,
	output_qty NUMERIC(24, 6) NOT NULL,
	material_cents BIGINT NOT NULL,
	labor_cents BIGINT NOT NULL,
	overhead_cents BIGINT NOT NULL,
	opening_wip_cents BIGINT NOT NULL,
	closing_wip_cents BIGINT NOT NULL,
	total_cents BIGINT NOT NULL,
	status VARCHAR(120) NOT NULL,
	version INTEGER NOT NULL,
	PRIMARY KEY (id),
	CHECK (total_cents = opening_wip_cents + material_cents + labor_cents + overhead_cents - closing_wip_cents),
	CHECK (output_qty > 0 AND total_cents >= 0),
	FOREIGN KEY(company_id) REFERENCES company (id),
	UNIQUE (production_id),
	FOREIGN KEY(production_id) REFERENCES document (id),
	FOREIGN KEY(material_id) REFERENCES material (id)
)

;

ALTER TABLE public."cost_calculation" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."cost_calculation" FROM anon, authenticated;


CREATE TABLE document_line (
	id SERIAL NOT NULL,
	document_id INTEGER NOT NULL,
	line_no INTEGER NOT NULL,
	material_id INTEGER,
	qty NUMERIC(24, 6) NOT NULL,
	unit_price_cents BIGINT NOT NULL,
	tax_rate NUMERIC(8, 6) NOT NULL,
	net_cents BIGINT NOT NULL,
	tax_cents BIGINT NOT NULL,
	total_cents BIGINT NOT NULL,
	cost_cents BIGINT NOT NULL,
	lot_id INTEGER,
	PRIMARY KEY (id),
	UNIQUE (document_id, line_no),
	CHECK (qty > 0),
	CHECK (total_cents = net_cents + tax_cents),
	CHECK (cost_cents >= 0),
	FOREIGN KEY(document_id) REFERENCES document (id),
	FOREIGN KEY(material_id) REFERENCES material (id),
	FOREIGN KEY(lot_id) REFERENCES lot (id)
)

;

CREATE INDEX ix_document_line_document_id ON document_line (document_id);

ALTER TABLE public."document_line" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."document_line" FROM anon, authenticated;


CREATE TABLE document_link (
	id SERIAL NOT NULL,
	source_id INTEGER NOT NULL,
	target_id INTEGER NOT NULL,
	relation VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (source_id, target_id, relation),
	CHECK (source_id <> target_id),
	FOREIGN KEY(source_id) REFERENCES document (id),
	FOREIGN KEY(target_id) REFERENCES document (id)
)

;

CREATE INDEX ix_document_link_source_id ON document_link (source_id);

CREATE INDEX ix_document_link_target_id ON document_link (target_id);

ALTER TABLE public."document_link" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."document_link" FROM anon, authenticated;


CREATE TABLE operation_report (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	production_id INTEGER NOT NULL,
	employee_id INTEGER NOT NULL,
	operation VARCHAR(120) NOT NULL,
	machine_hours NUMERIC(20, 4) NOT NULL,
	labor_hours NUMERIC(20, 4) NOT NULL,
	good_qty NUMERIC(24, 6) NOT NULL,
	scrap_qty NUMERIC(24, 6) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(production_id) REFERENCES document (id),
	FOREIGN KEY(employee_id) REFERENCES employee (id)
)

;

CREATE INDEX ix_operation_report_company_id ON operation_report (company_id);

CREATE INDEX ix_operation_report_production_id ON operation_report (production_id);

ALTER TABLE public."operation_report" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."operation_report" FROM anon, authenticated;


CREATE TABLE payment_schedule (
	id SERIAL NOT NULL,
	document_id INTEGER NOT NULL,
	due_date VARCHAR(10) NOT NULL,
	amount_cents BIGINT NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(document_id) REFERENCES document (id)
)

;

CREATE INDEX ix_payment_schedule_document_id ON payment_schedule (document_id);

ALTER TABLE public."payment_schedule" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."payment_schedule" FROM anon, authenticated;


CREATE TABLE production_detail (
	id SERIAL NOT NULL,
	document_id INTEGER NOT NULL,
	bom_id INTEGER NOT NULL,
	planned_qty NUMERIC(24, 6) NOT NULL,
	completed_qty NUMERIC(24, 6) NOT NULL,
	work_center VARCHAR(120) NOT NULL,
	start_date VARCHAR(10) NOT NULL,
	end_date VARCHAR(10) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (document_id),
	FOREIGN KEY(document_id) REFERENCES document (id),
	FOREIGN KEY(bom_id) REFERENCES bom (id)
)

;

ALTER TABLE public."production_detail" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."production_detail" FROM anon, authenticated;


CREATE TABLE sales_terms (
	id SERIAL NOT NULL,
	document_id INTEGER NOT NULL,
	department VARCHAR(120) NOT NULL,
	sales_group VARCHAR(120) NOT NULL,
	payment_terms VARCHAR(120) NOT NULL,
	delivery_method VARCHAR(120) NOT NULL,
	ship_from VARCHAR(120) NOT NULL,
	ship_to VARCHAR(120) NOT NULL,
	ship_address VARCHAR(300) NOT NULL,
	carrier VARCHAR(120) NOT NULL,
	vehicle_no VARCHAR(120) NOT NULL,
	price_includes_tax BOOLEAN NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (document_id),
	FOREIGN KEY(document_id) REFERENCES document (id)
)

;

ALTER TABLE public."sales_terms" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."sales_terms" FROM anon, authenticated;


CREATE TABLE settlement (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	bill_id INTEGER NOT NULL,
	cash_id INTEGER NOT NULL,
	amount_cents BIGINT NOT NULL,
	settled_on VARCHAR(10) NOT NULL,
	posting_key VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	CHECK (amount_cents > 0),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(bill_id) REFERENCES document (id),
	FOREIGN KEY(cash_id) REFERENCES document (id),
	UNIQUE (posting_key)
)

;

CREATE INDEX ix_settlement_bill_id ON settlement (bill_id);

CREATE INDEX ix_settlement_cash_id ON settlement (cash_id);

CREATE INDEX ix_settlement_company_id ON settlement (company_id);

ALTER TABLE public."settlement" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."settlement" FROM anon, authenticated;


CREATE TABLE voucher (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	document_id INTEGER NOT NULL,
	voucher_no VARCHAR(120) NOT NULL,
	posted_on VARCHAR(10) NOT NULL,
	period VARCHAR(7) NOT NULL,
	status VARCHAR(120) NOT NULL,
	posting_key VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	FOREIGN KEY(document_id) REFERENCES document (id),
	UNIQUE (voucher_no),
	UNIQUE (posting_key)
)

;

CREATE INDEX ix_voucher_company_id ON voucher (company_id);

CREATE INDEX ix_voucher_document_id ON voucher (document_id);

ALTER TABLE public."voucher" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."voucher" FROM anon, authenticated;


CREATE TABLE cost_allocation (
	id SERIAL NOT NULL,
	pool_id INTEGER NOT NULL,
	calculation_id INTEGER NOT NULL,
	basis_qty NUMERIC(24, 6) NOT NULL,
	allocated_cents BIGINT NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(pool_id) REFERENCES cost_pool (id),
	FOREIGN KEY(calculation_id) REFERENCES cost_calculation (id)
)

;

CREATE INDEX ix_cost_allocation_calculation_id ON cost_allocation (calculation_id);

CREATE INDEX ix_cost_allocation_pool_id ON cost_allocation (pool_id);

ALTER TABLE public."cost_allocation" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."cost_allocation" FROM anon, authenticated;


CREATE TABLE delivery_schedule (
	id SERIAL NOT NULL,
	line_id INTEGER NOT NULL,
	due_date VARCHAR(10) NOT NULL,
	qty NUMERIC(24, 6) NOT NULL,
	fulfilled_qty NUMERIC(24, 6) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(line_id) REFERENCES document_line (id)
)

;

CREATE INDEX ix_delivery_schedule_line_id ON delivery_schedule (line_id);

ALTER TABLE public."delivery_schedule" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."delivery_schedule" FROM anon, authenticated;


CREATE TABLE stock_transaction (
	id SERIAL NOT NULL,
	company_id INTEGER NOT NULL,
	line_id INTEGER NOT NULL,
	warehouse_id INTEGER NOT NULL,
	material_id INTEGER NOT NULL,
	lot_id INTEGER,
	posted_on VARCHAR(10) NOT NULL,
	qty_delta NUMERIC(24, 6) NOT NULL,
	cost_delta_cents BIGINT NOT NULL,
	posting_key VARCHAR(120) NOT NULL,
	PRIMARY KEY (id),
	FOREIGN KEY(company_id) REFERENCES company (id),
	UNIQUE (line_id),
	FOREIGN KEY(line_id) REFERENCES document_line (id),
	FOREIGN KEY(warehouse_id) REFERENCES warehouse (id),
	FOREIGN KEY(material_id) REFERENCES material (id),
	FOREIGN KEY(lot_id) REFERENCES lot (id),
	UNIQUE (posting_key)
)

;

CREATE INDEX ix_stock_transaction_company_id ON stock_transaction (company_id);

ALTER TABLE public."stock_transaction" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."stock_transaction" FROM anon, authenticated;


CREATE TABLE voucher_line (
	id SERIAL NOT NULL,
	voucher_id INTEGER NOT NULL,
	account_id INTEGER NOT NULL,
	debit_cents BIGINT NOT NULL,
	credit_cents BIGINT NOT NULL,
	PRIMARY KEY (id),
	CHECK ((debit_cents > 0 AND credit_cents = 0) OR (credit_cents > 0 AND debit_cents = 0)),
	FOREIGN KEY(voucher_id) REFERENCES voucher (id),
	FOREIGN KEY(account_id) REFERENCES gl_account (id)
)

;

CREATE INDEX ix_voucher_line_voucher_id ON voucher_line (voucher_id);

ALTER TABLE public."voucher_line" ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public."voucher_line" FROM anon, authenticated;

REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;

COMMIT;
