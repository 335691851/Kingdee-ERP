-- Standalone price application snapshots. No FK or write-back into ERP operational tables.
CREATE TABLE public.pricechangerecord (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 application_no text NOT NULL UNIQUE,
 group_company_code text NOT NULL,
 group_company_name text NOT NULL,
 applicant_company_code text NOT NULL,
 applicant_company_name text NOT NULL,
 applicant_legal_name_confirmed boolean NOT NULL,
 applicant_relationship_note text NOT NULL,
 sales_region text NOT NULL,
 province text NOT NULL DEFAULT '山东省',
 city text NOT NULL,
 category_level1 text NOT NULL,
 category_level2 text NOT NULL,
 material_code text NOT NULL,
 material_name text NOT NULL,
 model text NOT NULL,
 specification text NOT NULL,
 salt_origin text NOT NULL,
 packaging text NOT NULL,
 pack_weight_kg numeric(12,4),
 weight_scale text NOT NULL,
 min_quantity_ton numeric(14,3) NOT NULL,
 max_quantity_ton numeric(14,3),
 requested_quantity_ton numeric(14,3) NOT NULL,
 original_price numeric(14,2) NOT NULL CHECK(original_price>0),
 requested_price numeric(14,2) NOT NULL CHECK(requested_price>0),
 price_change_amount numeric(14,2) GENERATED ALWAYS AS (requested_price-original_price) STORED,
 price_change_percent numeric(12,4) GENERATED ALWAYS AS (round((requested_price-original_price)/original_price*100,4)) STORED,
 approved_price numeric(14,2),
 currency text NOT NULL DEFAULT 'CNY' CHECK(currency='CNY'),
 price_unit text NOT NULL DEFAULT '元/吨' CHECK(price_unit='元/吨'),
 price_includes_tax boolean NOT NULL DEFAULT true,
 tax_rate numeric(6,4) NOT NULL DEFAULT 0.13 CHECK(tax_rate>=0 AND tax_rate<=1),
 freight_included boolean NOT NULL DEFAULT false,
 application_scope text NOT NULL,
 project_code text NOT NULL,
 application_reason text NOT NULL,
 applied_at timestamptz NOT NULL,
 valid_from timestamptz NOT NULL,
 valid_to timestamptz NOT NULL,
 status text NOT NULL CHECK(status IN ('submitted','approved','rejected','withdrawn')),
 is_completed boolean GENERATED ALWAYS AS (status IN ('approved','rejected','withdrawn')) STORED,
 completed_at timestamptz,
 review_note text NOT NULL,
 is_simulated boolean NOT NULL DEFAULT true,
 source_basis text NOT NULL,
 seed_batch text NOT NULL,
 snapshot_as_of date NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(valid_to>valid_from AND valid_from>=applied_at),
 CHECK(completed_at IS NULL OR completed_at>=applied_at),
 CHECK((status='submitted' AND completed_at IS NULL) OR (status<>'submitted' AND completed_at IS NOT NULL)),
 CHECK((status='approved' AND approved_price IS NOT NULL AND approved_price>0 AND completed_at<=valid_from) OR (status<>'approved' AND approved_price IS NULL)),
 CHECK(pack_weight_kg IS NULL OR pack_weight_kg>0),
 CHECK(min_quantity_ton>=0 AND requested_quantity_ton>0 AND requested_quantity_ton>=min_quantity_ton AND (max_quantity_ton IS NULL OR (max_quantity_ton>min_quantity_ton AND requested_quantity_ton<max_quantity_ton)))
);
COMMENT ON TABLE public.pricechangerecord IS '鲁盐集团面向关联营销公司特殊价格申请独立静态快照；历史记录为模拟，合资股权属性待核实；不自动修改ERP目录价或单据';
COMMENT ON COLUMN public.pricechangerecord.original_price IS '原始目录价，含税人民币元/吨；取本地已交付ERP物料主数据，不声称为真实历史成交价';
COMMENT ON COLUMN public.pricechangerecord.requested_price IS '申请单价，含税人民币元/吨';
COMMENT ON COLUMN public.pricechangerecord.approved_price IS '审批通过后的执行价；未通过或未完成审批时为空；仅限对应专项项目';
COMMENT ON COLUMN public.pricechangerecord.price_change_amount IS '调价金额=申请价-原始价，元/吨，负数表示降价';
COMMENT ON COLUMN public.pricechangerecord.price_change_percent IS '调价幅度=(申请价-原始价)/原始价*100，百分数，例如-5表示降价5%';
COMMENT ON COLUMN public.pricechangerecord.is_completed IS '是否已结束申请审批流程；通过、驳回、撤回为true；不代表价格有效期已经结束';
COMMENT ON COLUMN public.pricechangerecord.valid_to IS '有效结束时刻，不含该时刻；仅审批通过的记录才有实际执行效力';
COMMENT ON COLUMN public.pricechangerecord.weight_scale IS '专项订单申请吨位区间；与单包包装重量pack_weight_kg分别记录';
COMMENT ON COLUMN public.pricechangerecord.model IS '取ERP的product_feature作为产品型号/特征，未虚构技术型号';
COMMENT ON COLUMN public.pricechangerecord.applicant_relationship_note IS '业务申请主体分组，不作为公司合资股权关系的事实证明';
CREATE INDEX ix_pricechangerecord_company_date ON public.pricechangerecord(applicant_company_code,applied_at DESC);
CREATE INDEX ix_pricechangerecord_region_material ON public.pricechangerecord(sales_region,category_level2,material_code);
CREATE INDEX ix_pricechangerecord_status_validity ON public.pricechangerecord(status,valid_from,valid_to);
ALTER TABLE public.pricechangerecord ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pricechangerecord FROM anon,authenticated;
REVOKE ALL ON SEQUENCE public.pricechangerecord_id_seq FROM anon,authenticated;
