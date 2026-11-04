-- Additive contract module DDL. Apply once to the existing ERP database.

BEGIN;

SET LOCAL search_path = public;


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

REVOKE ALL ON SEQUENCE public."sales_contract_id_seq" FROM anon, authenticated;


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

REVOKE ALL ON SEQUENCE public."contract_attachment_id_seq" FROM anon, authenticated;


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

REVOKE ALL ON SEQUENCE public."contract_category_id_seq" FROM anon, authenticated;


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

REVOKE ALL ON SEQUENCE public."contract_customer_id_seq" FROM anon, authenticated;


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

REVOKE ALL ON SEQUENCE public."contract_event_id_seq" FROM anon, authenticated;


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

REVOKE ALL ON SEQUENCE public."contract_price_id_seq" FROM anon, authenticated;


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

REVOKE ALL ON SEQUENCE public."contract_sku_id_seq" FROM anon, authenticated;

COMMIT;
