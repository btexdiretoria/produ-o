-- Safe baseline for a NEW and EMPTY PRODUÇÃO project.
-- Derived from the repository migrations in timestamp order.
-- Legacy public grants/policies and a one-off data deletion are intentionally omitted.
-- Applications access tables through service_role on the server.


-- Source: 20260808153820_9dd8e865-3194-4608-9c20-488fe5fe36c2.sql
CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  reference text NOT NULL,
  op_number text NOT NULL,
  brand text,
  total_quantity integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'em_producao',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.products TO service_role;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  name text NOT NULL,
  standard_time numeric,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX operations_product_id_idx ON public.operations(product_id);
GRANT ALL ON public.operations TO service_role;
ALTER TABLE public.operations ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  role text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.employees TO service_role;
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.schedule_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  start_time time NOT NULL DEFAULT '07:00',
  end_time time NOT NULL DEFAULT '17:00',
  slot_minutes integer NOT NULL DEFAULT 60,
  breaks jsonb NOT NULL DEFAULT '[{"start":"11:00","end":"12:00","label":"Almoço"}]'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.schedule_config TO service_role;
ALTER TABLE public.schedule_config ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.production_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL REFERENCES public.operations(id) ON DELETE CASCADE,
  slot_start time NOT NULL,
  slot_end time NOT NULL,
  quantity integer NOT NULL DEFAULT 0,
  entry_date date NOT NULL DEFAULT CURRENT_DATE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX production_entries_date_idx ON public.production_entries(entry_date);
CREATE INDEX production_entries_product_idx ON public.production_entries(product_id);
GRANT ALL ON public.production_entries TO service_role;
ALTER TABLE public.production_entries ENABLE ROW LEVEL SECURITY;
INSERT INTO public.schedule_config (start_time, end_time, slot_minutes) VALUES ('07:00','17:00',60);


-- Source: 20260808165159_ad7de730-5cd6-4e57-b517-969b24ec9c2b.sql
ALTER TABLE public.products RENAME COLUMN brand TO cliente;
ALTER TABLE public.products
  ADD COLUMN empresa text,
  ADD COLUMN unit_value numeric NOT NULL DEFAULT 0,
  ADD COLUMN entry_date date,
  ADD COLUMN nf_number text;

CREATE TABLE public.companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.companies TO service_role;
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;


-- Source: 20260808172435_1ec0a0ac-41e7-4ea8-8e03-a10a5a446e28.sql

CREATE TABLE public.clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.clients TO service_role;
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.sectors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.sectors TO service_role;
ALTER TABLE public.sectors ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.catalog_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sector_id uuid NOT NULL REFERENCES public.sectors(id) ON DELETE CASCADE,
  name text NOT NULL,
  expected_per_hour numeric,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.catalog_operations TO service_role;
ALTER TABLE public.catalog_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operations ADD COLUMN IF NOT EXISTS catalog_operation_id uuid REFERENCES public.catalog_operations(id) ON DELETE SET NULL;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS photo_url text;
ALTER TABLE public.products ALTER COLUMN status SET DEFAULT 'em_estoque';

INSERT INTO public.clients (name)
SELECT DISTINCT cliente FROM public.products WHERE cliente IS NOT NULL AND cliente <> '';

INSERT INTO public.sectors (name) VALUES ('Corte'), ('Costura'), ('Acabamento'), ('Revisão'), ('Embalagem');

CREATE OR REPLACE FUNCTION public.mark_product_in_production()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF NEW.quantity > 0 THEN
    UPDATE public.products SET status = 'em_producao', updated_at = now()
    WHERE id = NEW.product_id AND status <> 'em_producao';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mark_product_in_production ON public.production_entries;
CREATE TRIGGER trg_mark_product_in_production
AFTER INSERT OR UPDATE OF quantity ON public.production_entries
FOR EACH ROW EXECUTE FUNCTION public.mark_product_in_production();

UPDATE public.products p SET status = CASE
  WHEN EXISTS (SELECT 1 FROM public.production_entries e WHERE e.product_id = p.id AND e.quantity > 0)
  THEN 'em_producao' ELSE 'em_estoque' END;


-- Source: 20260808172451_0523987e-7ba7-45a1-8571-b25a47921fbc.sql
REVOKE EXECUTE ON FUNCTION public.mark_product_in_production() FROM PUBLIC, anon, authenticated;


-- Source: 20260810163831_8fc9f839-c9b0-420b-920c-4c87b0a517f9.sql
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS delivery_date date,
  ADD COLUMN IF NOT EXISTS forecast_date date,
  ADD COLUMN IF NOT EXISTS nf_out_number text;


-- Source: 20260810172747_d9fd8f4e-0c0c-4d23-995d-0d0e27fa1854.sql
CREATE OR REPLACE FUNCTION public.recalc_product_status(_product_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  _total int;
  _ops int;
  _done int;
  _produced int;
  _new text;
BEGIN
  SELECT total_quantity INTO _total FROM public.products WHERE id = _product_id;
  IF _total IS NULL THEN RETURN; END IF;

  SELECT count(*) INTO _ops FROM public.operations WHERE product_id = _product_id;

  SELECT COALESCE(sum(quantity),0) INTO _produced
  FROM public.production_entries WHERE product_id = _product_id;

  SELECT count(*) INTO _done FROM (
    SELECT o.id
    FROM public.operations o
    LEFT JOIN public.production_entries pe ON pe.operation_id = o.id
    WHERE o.product_id = _product_id
    GROUP BY o.id
    HAVING COALESCE(sum(pe.quantity),0) >= _total
  ) t;

  IF _produced <= 0 THEN
    _new := 'em_estoque';
  ELSIF _ops > 0 AND _done = _ops AND _total > 0 THEN
    _new := 'finalizado';
  ELSE
    _new := 'em_producao';
  END IF;

  UPDATE public.products
  SET status = _new, updated_at = now()
  WHERE id = _product_id AND status IS DISTINCT FROM _new;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_product_in_production()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.recalc_product_status(OLD.product_id);
    RETURN OLD;
  END IF;
  PERFORM public.recalc_product_status(NEW.product_id);
  IF TG_OP = 'UPDATE' AND OLD.product_id IS DISTINCT FROM NEW.product_id THEN
    PERFORM public.recalc_product_status(OLD.product_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mark_product_in_production ON public.production_entries;
CREATE TRIGGER trg_mark_product_in_production
AFTER INSERT OR UPDATE OR DELETE ON public.production_entries
FOR EACH ROW EXECUTE FUNCTION public.mark_product_in_production();

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.products LOOP
    PERFORM public.recalc_product_status(r.id);
  END LOOP;
END $$;


-- Source: 20260810172805_55b60e48-ecfe-4b3f-90ee-2a2c6a2127ae.sql
REVOKE ALL ON FUNCTION public.recalc_product_status(uuid) FROM PUBLIC, anon, authenticated;


-- Source: 20260810174604_8f6de515-8db9-4aba-9665-7291033295b8.sql
ALTER TABLE public.catalog_operations ADD COLUMN IF NOT EXISTS is_last_operation boolean NOT NULL DEFAULT false;


-- Source: 20260810180120_e4841d43-01f8-4e76-855f-4efc04922372.sql
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS pilot_photos text[] NOT NULL DEFAULT '{}'::text[];


-- Source: 20260811152832_5cd00ba0-3a5e-4772-a36a-f9153ef1054c.sql
CREATE TABLE public.marcadores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL UNIQUE,
  senha_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT ALL ON public.marcadores TO service_role;

ALTER TABLE public.marcadores ENABLE ROW LEVEL SECURITY;

CREATE POLICY "marcadores_service_role_only" ON public.marcadores
FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$
LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER update_marcadores_updated_at BEFORE UPDATE ON public.marcadores
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- Source: 20260811153814_5d593cb0-a165-4182-85ff-e8235f6a1dbb.sql
ALTER TABLE public.marcadores
  ADD COLUMN IF NOT EXISTS cargo text NOT NULL DEFAULT 'usuario';

ALTER TABLE public.marcadores
  ADD CONSTRAINT marcadores_cargo_check CHECK (cargo IN ('usuario','admin'));

UPDATE public.marcadores SET cargo = 'admin';


-- Source: 20260811163044_b29768b7-3e3d-4a6c-908c-e41464ff6017.sql
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS op_interna text;

CREATE TABLE public.esteira_producao (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  produto_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  data_adicionado timestamp with time zone NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'ativo',
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  UNIQUE (produto_id)
);

GRANT ALL ON public.esteira_producao TO service_role;

ALTER TABLE public.esteira_producao ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER update_esteira_producao_updated_at
  BEFORE UPDATE ON public.esteira_producao
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- Source: 20260811163904_92a58de6-2c3b-4661-8dda-c2a86e660d93.sql
DROP POLICY IF EXISTS esteira_producao_public_all ON public.esteira_producao;

REVOKE INSERT, UPDATE, DELETE ON public.esteira_producao FROM anon, authenticated;
GRANT ALL ON public.esteira_producao TO service_role;

CREATE POLICY esteira_producao_service_all ON public.esteira_producao
FOR ALL TO service_role USING (true) WITH CHECK (true);


-- Source: 20260811172849_6c27107c-2476-494b-9ebf-bb1a559e55d4.sql
CREATE TABLE public.overtime_slots (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  start_time time without time zone NOT NULL,
  end_time time without time zone NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

GRANT ALL ON public.overtime_slots TO service_role;

ALTER TABLE public.overtime_slots ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER update_overtime_slots_updated_at
BEFORE UPDATE ON public.overtime_slots
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.production_entries
  ADD COLUMN is_overtime boolean NOT NULL DEFAULT false;


-- Source: 20260811193947_5f2e8eb6-9634-4f00-abd0-43a72d7e60fd.sql
DO $$
DECLARE t text; p record;
BEGIN
  FOREACH t IN ARRAY ARRAY['products','operations','employees','schedule_config','production_entries','companies','clients','sectors','catalog_operations','overtime_slots','esteira_producao']
  LOOP
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', p.policyname, t);
    END LOOP;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', t||'_service_role_only', t);
  END LOOP;
END $$;

DO $$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND (coalesce(qual,'') LIKE '%product-files%' OR coalesce(with_check,'') LIKE '%product-files%')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', p.policyname);
  END LOOP;
END $$;


-- Source: 20260812145507_ad1d9c4c-2950-46d9-b203-d1c439ffba30.sql
ALTER TABLE public.operations
  ADD COLUMN IF NOT EXISTS is_last_operation boolean NOT NULL DEFAULT false;

UPDATE public.operations o
SET is_last_operation = true
FROM public.catalog_operations c
WHERE o.catalog_operation_id = c.id
  AND c.is_last_operation = true
  AND o.is_last_operation = false;


-- Source: 20260814220144_3323a783-acf0-435f-ac8d-813136ab49ca.sql
CREATE TABLE public.faturamento_meses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mes int NOT NULL CHECK (mes BETWEEN 1 AND 12),
  ano int NOT NULL CHECK (ano BETWEEN 2000 AND 2100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mes, ano)
);
GRANT ALL ON public.faturamento_meses TO service_role;
ALTER TABLE public.faturamento_meses ENABLE ROW LEVEL SECURITY;
CREATE POLICY faturamento_meses_service_role_only ON public.faturamento_meses FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE TRIGGER update_faturamento_meses_updated_at BEFORE UPDATE ON public.faturamento_meses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TABLE public.faturamento_mes_produtos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mes_id uuid NOT NULL REFERENCES public.faturamento_meses(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mes_id, product_id)
);
GRANT ALL ON public.faturamento_mes_produtos TO service_role;
ALTER TABLE public.faturamento_mes_produtos ENABLE ROW LEVEL SECURITY;
CREATE POLICY faturamento_mes_produtos_service_role_only ON public.faturamento_mes_produtos FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE TABLE public.meta_setor_mes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sector_id uuid NOT NULL REFERENCES public.sectors(id) ON DELETE CASCADE,
  mes int NOT NULL CHECK (mes BETWEEN 1 AND 12),
  ano int NOT NULL CHECK (ano BETWEEN 2000 AND 2100),
  meta_dia numeric NOT NULL DEFAULT 0,
  feriados text[] NOT NULL DEFAULT '{}'::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sector_id, mes, ano)
);
GRANT ALL ON public.meta_setor_mes TO service_role;
ALTER TABLE public.meta_setor_mes ENABLE ROW LEVEL SECURITY;
CREATE POLICY meta_setor_mes_service_role_only ON public.meta_setor_mes FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE TRIGGER update_meta_setor_mes_updated_at BEFORE UPDATE ON public.meta_setor_mes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- Source: 20260814225828_dad9097a-49d4-4999-9695-8c18b13698ec.sql
ALTER TABLE public.meta_setor_mes ADD COLUMN IF NOT EXISTS dias_encerrados text[] NOT NULL DEFAULT '{}'::text[];


-- Source: 20260815143502_31705289-d4d5-4a27-b7ed-f3788a13ce59.sql
CREATE TABLE public.meta_producao_setor_dia (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sector_id uuid NOT NULL REFERENCES public.sectors(id) ON DELETE CASCADE,
  data date NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  quantidade integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sector_id, data, product_id)
);

GRANT ALL ON public.meta_producao_setor_dia TO service_role;

ALTER TABLE public.meta_producao_setor_dia ENABLE ROW LEVEL SECURITY;

CREATE POLICY meta_producao_setor_dia_service_role_only
  ON public.meta_producao_setor_dia
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE TRIGGER update_meta_producao_setor_dia_updated_at
  BEFORE UPDATE ON public.meta_producao_setor_dia
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- Source: 20260815185523_82c5cb39-e2fc-4a00-94ad-6d1b42bd948d.sql
CREATE TABLE public.ocorrencias (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT ALL ON public.ocorrencias TO service_role;

ALTER TABLE public.ocorrencias ENABLE ROW LEVEL SECURITY;

CREATE POLICY ocorrencias_service_role_only ON public.ocorrencias
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

ALTER TABLE public.production_entries
  ADD COLUMN ocorrencia_id uuid REFERENCES public.ocorrencias(id) ON DELETE SET NULL;


-- Source: 20260815191220_de6302ec-8ef1-4bbe-90b4-3239945c083c.sql
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS numero_id integer;

WITH ordered AS (
  SELECT id, row_number() OVER (ORDER BY name, created_at) + 9 AS n
  FROM public.employees
)
UPDATE public.employees e SET numero_id = o.n FROM ordered o WHERE e.id = o.id AND e.numero_id IS NULL;

CREATE SEQUENCE IF NOT EXISTS public.employees_numero_id_seq AS integer START WITH 10;

SELECT setval('public.employees_numero_id_seq', GREATEST((SELECT COALESCE(max(numero_id), 9) FROM public.employees), 9));

ALTER TABLE public.employees ALTER COLUMN numero_id SET DEFAULT nextval('public.employees_numero_id_seq');
ALTER TABLE public.employees ALTER COLUMN numero_id SET NOT NULL;
ALTER SEQUENCE public.employees_numero_id_seq OWNED BY public.employees.numero_id;

CREATE UNIQUE INDEX IF NOT EXISTS employees_numero_id_key ON public.employees (numero_id);


-- Source: 20260815192031_1317a31e-cf27-4fe2-ad09-1f28da0f6418.sql
CREATE TABLE public.schedule_day_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekday integer NOT NULL UNIQUE CHECK (weekday BETWEEN 0 AND 6),
  start_time time NOT NULL DEFAULT '07:00',
  end_time time NOT NULL DEFAULT '17:00',
  slot_minutes integer NOT NULL DEFAULT 60,
  breaks jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_folga boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.schedule_day_config TO service_role;
ALTER TABLE public.schedule_day_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY schedule_day_config_service_role_only ON public.schedule_day_config FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE TRIGGER update_schedule_day_config_updated_at BEFORE UPDATE ON public.schedule_day_config FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TABLE public.feriados (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  data date NOT NULL UNIQUE,
  nome text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.feriados TO service_role;
ALTER TABLE public.feriados ENABLE ROW LEVEL SECURITY;
CREATE POLICY feriados_service_role_only ON public.feriados FOR ALL TO service_role USING (true) WITH CHECK (true);

INSERT INTO public.schedule_day_config (weekday, start_time, end_time, slot_minutes, breaks, is_folga)
SELECT w.weekday,
       COALESCE(c.start_time, '07:00'::time),
       COALESCE(c.end_time, '17:00'::time),
       COALESCE(c.slot_minutes, 60),
       COALESCE(c.breaks, '[]'::jsonb),
       w.weekday IN (0, 6)
FROM (SELECT generate_series(0, 6) AS weekday) w
LEFT JOIN LATERAL (SELECT * FROM public.schedule_config LIMIT 1) c ON true;


-- Source: 20260816182014_11fa337d-4d08-4267-8e31-b11dc99d3cb5.sql
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS peca_piloto text,
  DROP COLUMN IF EXISTS pilot_photos;

ALTER TABLE public.products
  ADD CONSTRAINT products_peca_piloto_check
  CHECK (peca_piloto IS NULL OR peca_piloto IN ('sim','nao','devolvido'));


-- Source: 20260818110428_92f8ef90-dd4d-4304-a78b-46a7d5606961.sql
-- 1. Esteira: múltiplas frações por produto
ALTER TABLE public.esteira_producao DROP CONSTRAINT IF EXISTS esteira_producao_produto_id_key;
ALTER TABLE public.esteira_producao
  ADD COLUMN IF NOT EXISTS op_interna text,
  ADD COLUMN IF NOT EXISTS quantidade integer NOT NULL DEFAULT 0;

UPDATE public.esteira_producao e
SET op_interna = COALESCE(e.op_interna, p.op_interna),
    quantidade = CASE WHEN e.quantidade > 0 THEN e.quantidade ELSE COALESCE(p.total_quantity, 0) END
FROM public.products p
WHERE p.id = e.produto_id;

CREATE UNIQUE INDEX IF NOT EXISTS esteira_producao_produto_op_interna_ativo_idx
  ON public.esteira_producao (produto_id, op_interna)
  WHERE status = 'ativo';

-- 2. Marcações ligadas à fração
ALTER TABLE public.production_entries
  ADD COLUMN IF NOT EXISTS lote_id uuid REFERENCES public.esteira_producao(id) ON DELETE SET NULL;

UPDATE public.production_entries pe
SET lote_id = e.id
FROM public.esteira_producao e
WHERE pe.lote_id IS NULL
  AND e.produto_id = pe.product_id
  AND e.status = 'ativo';

CREATE INDEX IF NOT EXISTS production_entries_lote_id_idx ON public.production_entries (lote_id);

-- 3. Metas de produção por fração
ALTER TABLE public.meta_producao_setor_dia
  ADD COLUMN IF NOT EXISTS lote_id uuid REFERENCES public.esteira_producao(id) ON DELETE CASCADE;

UPDATE public.meta_producao_setor_dia m
SET lote_id = e.id
FROM public.esteira_producao e
WHERE m.lote_id IS NULL AND e.produto_id = m.product_id AND e.status = 'ativo';

ALTER TABLE public.meta_producao_setor_dia
  DROP CONSTRAINT IF EXISTS meta_producao_setor_dia_sector_id_data_product_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS meta_producao_setor_dia_sector_data_lote_idx
  ON public.meta_producao_setor_dia (sector_id, data, product_id, lote_id);

-- 4. Status do produto considera todas as frações
CREATE OR REPLACE FUNCTION public.recalc_product_status(_product_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  _ops int;
  _produced int;
  _lotes int;
  _new text;
BEGIN
  SELECT count(*) INTO _ops FROM public.operations WHERE product_id = _product_id;

  SELECT COALESCE(sum(quantity),0) INTO _produced
  FROM public.production_entries WHERE product_id = _product_id;

  SELECT count(*) INTO _lotes
  FROM public.esteira_producao
  WHERE produto_id = _product_id AND status = 'ativo';

  IF _produced <= 0 THEN
    _new := 'em_estoque';
  ELSIF _ops > 0 AND _lotes > 0 AND NOT EXISTS (
    SELECT 1
    FROM public.esteira_producao l
    WHERE l.produto_id = _product_id
      AND l.status = 'ativo'
      AND (
        l.quantidade <= 0
        OR EXISTS (
          SELECT 1 FROM public.operations o
          WHERE o.product_id = _product_id
            AND COALESCE((
              SELECT sum(pe.quantity) FROM public.production_entries pe
              WHERE pe.operation_id = o.id AND pe.lote_id = l.id
            ), 0) < l.quantidade
        )
      )
  ) THEN
    _new := 'finalizado';
  ELSE
    _new := 'em_producao';
  END IF;

  UPDATE public.products
  SET status = _new, updated_at = now()
  WHERE id = _product_id AND status IS DISTINCT FROM _new;
END;
$function$;


-- Source: 20260818121432_a3f821b8-6b91-45a0-8bf3-1760f00ead55.sql
ALTER TABLE public.faturamento_mes_produtos
  ADD COLUMN IF NOT EXISTS lote_id uuid REFERENCES public.esteira_producao(id) ON DELETE CASCADE;

INSERT INTO public.faturamento_mes_produtos (mes_id, product_id, lote_id)
SELECT f.mes_id, f.product_id, e.id
FROM public.faturamento_mes_produtos f
JOIN public.esteira_producao e ON e.produto_id = f.product_id
WHERE f.lote_id IS NULL
  AND e.status IN ('ativo','removido')
ON CONFLICT DO NOTHING;

CREATE UNIQUE INDEX IF NOT EXISTS faturamento_mes_produtos_lote_uniq
  ON public.faturamento_mes_produtos (mes_id, product_id, lote_id)
  WHERE lote_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS faturamento_mes_produtos_master_uniq
  ON public.faturamento_mes_produtos (mes_id, product_id)
  WHERE lote_id IS NULL;


-- Source: 20260818122040_ad7fcc29-1a44-46c0-b03c-c1627fe04214.sql
ALTER TABLE public.faturamento_mes_produtos DROP CONSTRAINT IF EXISTS faturamento_mes_produtos_mes_id_product_id_key;


-- Source: 20260818223009_4d4cd6b0-1cfa-4711-87c4-9e405e0657d9.sql
ALTER TABLE public.production_entries DROP CONSTRAINT production_entries_lote_id_fkey;
ALTER TABLE public.production_entries ADD CONSTRAINT production_entries_lote_id_fkey FOREIGN KEY (lote_id) REFERENCES public.esteira_producao(id) ON DELETE RESTRICT;


-- Source: 20260823213750_4b1b43e4-6ccd-4250-9301-c3fd36e62582.sql
CREATE TABLE public.meta_simulacoes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sector_id uuid NOT NULL REFERENCES public.sectors(id) ON DELETE CASCADE,
  mes integer NOT NULL,
  ano integer NOT NULL,
  nome text NOT NULL,
  itens jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT ALL ON public.meta_simulacoes TO service_role;

ALTER TABLE public.meta_simulacoes ENABLE ROW LEVEL SECURITY;

CREATE POLICY meta_simulacoes_service_role_only ON public.meta_simulacoes
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE TRIGGER update_meta_simulacoes_updated_at
  BEFORE UPDATE ON public.meta_simulacoes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- Source: 20260823221507_f88aebee-a743-45ba-9f28-f8168b9dc208.sql
ALTER TABLE public.marcadores
  ADD COLUMN IF NOT EXISTS setor_id uuid REFERENCES public.sectors(id) ON DELETE SET NULL;

CREATE TABLE public.avisos (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  texto text NOT NULL,
  criado_por uuid REFERENCES public.marcadores(id) ON DELETE SET NULL,
  criado_por_nome text NOT NULL,
  resolvido boolean NOT NULL DEFAULT false,
  resolvido_por uuid REFERENCES public.marcadores(id) ON DELETE SET NULL,
  resolvido_por_nome text,
  resolvido_em timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

GRANT ALL ON public.avisos TO service_role;

ALTER TABLE public.avisos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "avisos_service_role_only" ON public.avisos
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE TRIGGER update_avisos_updated_at
  BEFORE UPDATE ON public.avisos
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX idx_avisos_resolvido_created ON public.avisos (resolvido, created_at DESC);


-- Source: 20260823223054_bba33b37-0162-48a7-adcd-f88446588529.sql
ALTER TABLE public.marcadores DROP CONSTRAINT IF EXISTS marcadores_cargo_check;

ALTER TABLE public.marcadores
  ADD CONSTRAINT marcadores_cargo_check
  CHECK (cargo IN ('admin', 'usuario', 'setor'));

ALTER TABLE public.marcadores DROP CONSTRAINT IF EXISTS marcadores_setor_coerente_check;

ALTER TABLE public.marcadores
  ADD CONSTRAINT marcadores_setor_coerente_check
  CHECK (
    (cargo = 'setor' AND setor_id IS NOT NULL)
    OR (cargo <> 'setor' AND setor_id IS NULL)
  );


-- Source: 20260915190426_1a7f286d-a50f-4568-8d17-32ce6faf0990.sql
ALTER TABLE public.marcadores DROP CONSTRAINT IF EXISTS marcadores_cargo_check;
ALTER TABLE public.marcadores ADD CONSTRAINT marcadores_cargo_check CHECK (cargo IN ('admin','usuario','setor','painel'));
ALTER TABLE public.marcadores DROP CONSTRAINT IF EXISTS marcadores_setor_coerente_check;
ALTER TABLE public.marcadores ADD CONSTRAINT marcadores_setor_coerente_check CHECK ((cargo = 'setor' AND setor_id IS NOT NULL) OR (cargo <> 'setor' AND setor_id IS NULL));

-- Explicit privileges needed by server-side writes on a fresh Supabase project.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.employees_numero_id_seq TO service_role;
GRANT EXECUTE ON FUNCTION public.update_updated_at_column() TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_product_in_production() TO service_role;
GRANT EXECUTE ON FUNCTION public.recalc_product_status(uuid) TO service_role;
