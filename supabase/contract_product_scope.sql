BEGIN;

SET LOCAL search_path=public;


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

ALTER TABLE public.contract_category ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.contract_category FROM anon,authenticated;

REVOKE ALL ON SEQUENCE public.contract_category_id_seq FROM anon,authenticated;


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

ALTER TABLE public.contract_sku ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.contract_sku FROM anon,authenticated;

REVOKE ALL ON SEQUENCE public.contract_sku_id_seq FROM anon,authenticated;

COMMIT;
