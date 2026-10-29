-- Esquema de la base de datos de PRUEBA en Supabase (varios barcos)
-- Proyecto: "Mantenimiento Naval" (ncughlkgdgigwkggnxri), usado por la versión de prueba (prueba/index.html).
-- La base REAL (la que usa index.html de la raíz) sigue documentada en docs/esquema.sql.
-- Todas las tablas usan prefijo mant_ y tienen RLS activado
-- Refleja la base de prueba al 2026-10-29. Si hay dudas, la fuente de verdad es el proyecto en Supabase.
--
-- VARIOS BARCOS:
-- - mant_buque es la tabla de barcos: una fila por barco (id 1 = B/M Santa Lucía).
-- - Todas las demás tablas mant_* tienen barco_id NOT NULL -> mant_buque(id).
--   El DEFAULT 1 (Santa Lucía) es TEMPORAL, para que la app siga andando sin mandar barco_id; se saca en el Paso 5.
-- - Las tablas que tienen hijas tienen UNIQUE (barco_id, id) y las hijas las referencian por (barco_id, x_id),
--   así la base rechaza mezclar barcos (p. ej. una tarea de un barco con un equipo de otro).

-- =============== BARCOS (mant_buque: una fila por barco) ===============
CREATE TABLE public.mant_buque (
  id SERIAL PRIMARY KEY,
  nombre TEXT NOT NULL DEFAULT 'B/M Santa Lucía',
  tipo TEXT,
  astillero TEXT,
  pais_origen TEXT,
  anio_construccion INTEGER,
  fecha_botadura TEXT,
  casco_nro TEXT,
  registro_nro TEXT,
  matricula TEXT,
  senal_distintiva TEXT,
  bandera TEXT DEFAULT 'Uruguay',
  eslora_m NUMERIC,
  eslora_total_m NUMERIC,
  eslora_zdl_m NUMERIC,
  manga_m NUMERIC,
  puntal_m NUMERIC,
  calado_min_m NUMERIC,
  calado_max_m NUMERIC,
  capacidad_dw_t NUMERIC,
  velocidad_nudos NUMERIC,
  sobre_estacas_t NUMERIC,
  tonelaje_total_t NUMERIC,
  desplazamiento_tm NUMERIC,
  trb NUMERIC,
  trn NUMERIC,
  rango_accion_millas NUMERIC,
  material_casco TEXT,
  tipo_navegacion TEXT,
  clase_buque TEXT,
  clase_maquina TEXT,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== EQUIPOS (fichas) ===============
-- Los equipos no se borran: se marcan activo = false.
CREATE TABLE public.mant_equipos (
  id SERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  nombre TEXT NOT NULL,
  categoria TEXT,
  cantidad INTEGER DEFAULT 1,
  ubicacion_abordo TEXT,
  fabricante TEXT,
  modelo TEXT,
  numero_serie TEXT,
  anio_fab INTEGER,
  anio_instalacion INTEGER,
  datos_tecnicos TEXT,
  potencia_kw NUMERIC,
  potencia_hp NUMERIC,
  consumo_lh NUMERIC,
  rpm_nominal INTEGER,
  voltaje TEXT,
  amperaje TEXT,
  combustible TEXT,
  tipo_refrigeracion TEXT,
  aceite_tipo TEXT,
  capacidad_aceite_l NUMERIC,
  proveedor_local TEXT,
  estado TEXT DEFAULT 'Operativo',
  notas TEXT,
  activo BOOLEAN DEFAULT true,
  critico BOOLEAN NOT NULL DEFAULT false,   -- su falla genera riesgo de seguridad
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_equipos_barco_id_id_key UNIQUE (barco_id, id)
);

-- =============== TAREAS DE MANTENIMIENTO ===============
CREATE TABLE public.mant_tareas (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  equipo TEXT NOT NULL,                     -- nombre del equipo (texto libre; filtros y carga de horas usan esto)
  equipo_id INTEGER,                        -- equipo del mismo barco (FK compuesta abajo)
  tarea TEXT NOT NULL,
  periodicidad TEXT,                        -- solo para mostrar ("250 hrs", "Mensual", "250 hrs o 6 meses")
  -- Control: 'hrs' (cada_hrs), 'fecha' (cada_meses), 'ambos' (lo que ocurra primero), 'ninguna'
  unidad TEXT CONSTRAINT mant_tareas_unidad_check
    CHECK (unidad IN ('hrs', 'fecha', 'ambos', 'ninguna')) DEFAULT 'hrs',
  cada_hrs NUMERIC CHECK (cada_hrs > 0),    -- intervalo en horas (lo usa el cálculo)
  cada_meses INTEGER CHECK (cada_meses > 0), -- intervalo en meses (lo usa el cálculo)
  hrs_totales NUMERIC DEFAULT 0,
  ult_hrs NUMERIC,
  fecha_ult DATE,
  proxima_hrs NUMERIC,
  proxima_fecha DATE,
  prioridad TEXT CHECK (prioridad IN ('ALTA', 'MEDIA', 'BAJA')) DEFAULT 'MEDIA',
  -- Tipo de trabajo del plan de mantenimiento (descripciones en TIPOS_TRABAJO en index.html):
  -- I Inspección, IL Inspección con toma de luces, O Overhauling, OH Overhaul completo, L Limpieza,
  -- T Chequeo/Test, R Reemplazo, A Análisis, MT Chequeo con Megger, E Engrase/Lubricación
  tipo_trabajo TEXT CONSTRAINT mant_tareas_tipo_trabajo_check
    CHECK (tipo_trabajo IN ('I', 'IL', 'O', 'OH', 'L', 'T', 'R', 'A', 'MT', 'E')),
  realizado_por TEXT,
  estado_op TEXT DEFAULT 'Operativo',
  observaciones TEXT,
  activa BOOLEAN DEFAULT true,
  -- Postergación: mientras postergada_hasta sea hoy o futura, la tarea no cuenta en las alertas del Dashboard
  postergada_hasta DATE,
  motivo_postergacion TEXT,
  creada_en TIMESTAMPTZ DEFAULT now(),
  actualizada_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_tareas_postergacion_check
    CHECK ((postergada_hasta IS NULL) = (motivo_postergacion IS NULL)),
  -- Cada tipo de control tiene su intervalo
  CONSTRAINT mant_tareas_control_check CHECK (
    (unidad NOT IN ('hrs', 'ambos') OR cada_hrs IS NOT NULL) AND
    (unidad NOT IN ('fecha', 'ambos') OR cada_meses IS NOT NULL)),
  CONSTRAINT mant_tareas_barco_id_id_key UNIQUE (barco_id, id),
  -- Al borrar el equipo, solo equipo_id queda en NULL (barco_id se mantiene)
  CONSTRAINT mant_tareas_equipo_id_fkey FOREIGN KEY (barco_id, equipo_id)
    REFERENCES public.mant_equipos(barco_id, id) ON DELETE SET NULL (equipo_id)
);

-- =============== HISTORIAL ===============
CREATE TABLE public.mant_historial (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  tarea_id BIGINT NOT NULL,
  fecha_realizado DATE NOT NULL,
  hrs_equipo NUMERIC,
  realizado_por TEXT,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_historial_tarea_id_fkey FOREIGN KEY (barco_id, tarea_id)
    REFERENCES public.mant_tareas(barco_id, id) ON DELETE CASCADE
);

-- =============== REPUESTOS ===============
CREATE TABLE public.mant_repuestos (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  nombre TEXT NOT NULL,
  codigo TEXT,
  categoria TEXT,
  subcategoria TEXT,
  cantidad NUMERIC NOT NULL DEFAULT 0,
  minimo NUMERIC NOT NULL DEFAULT 0,
  unidad TEXT DEFAULT 'unidad',
  proveedor TEXT,
  ubicacion TEXT,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_repuestos_barco_id_id_key UNIQUE (barco_id, id)
);

-- =============== MOVIMIENTOS DE STOCK ===============
CREATE TABLE public.mant_movimientos (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  repuesto_id BIGINT NOT NULL,
  tipo TEXT NOT NULL CHECK (tipo IN ('entrada', 'salida', 'ajuste')),
  cantidad NUMERIC NOT NULL,
  motivo TEXT,
  tarea_id BIGINT,
  fecha TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_movimientos_repuesto_id_fkey FOREIGN KEY (barco_id, repuesto_id)
    REFERENCES public.mant_repuestos(barco_id, id) ON DELETE CASCADE,
  CONSTRAINT mant_movimientos_tarea_id_fkey FOREIGN KEY (barco_id, tarea_id)
    REFERENCES public.mant_tareas(barco_id, id) ON DELETE SET NULL (tarea_id)
);

-- =============== VÍNCULO TAREA-REPUESTOS ===============
CREATE TABLE public.mant_tarea_repuestos (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  tarea_id BIGINT NOT NULL,
  repuesto_id BIGINT NOT NULL,
  cantidad_usada NUMERIC NOT NULL DEFAULT 1,
  UNIQUE(tarea_id, repuesto_id),            -- la tarea ya es de un barco
  CONSTRAINT mant_tarea_repuestos_tarea_id_fkey FOREIGN KEY (barco_id, tarea_id)
    REFERENCES public.mant_tareas(barco_id, id) ON DELETE CASCADE,
  CONSTRAINT mant_tarea_repuestos_repuesto_id_fkey FOREIGN KEY (barco_id, repuesto_id)
    REFERENCES public.mant_repuestos(barco_id, id) ON DELETE CASCADE
);

-- =============== HERRAMIENTAS ===============
CREATE TABLE public.mant_herramientas (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  nombre TEXT NOT NULL,
  marca TEXT,
  cantidad NUMERIC NOT NULL DEFAULT 1,
  ubicacion TEXT,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== LECTURAS DE HORAS (histórico mensual) ===============
-- Una fila por equipo cada vez que se guardan las horas del mes (pestaña Cargar Horas).
-- Se identifica el equipo por NOMBRE, no por id.
CREATE TABLE public.mant_lecturas_horas (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  equipo TEXT NOT NULL,
  fecha DATE NOT NULL,
  horas_mes NUMERIC,                        -- horas sumadas en el mes
  hrs_total NUMERIC,                        -- horas acumuladas del equipo
  creado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== DEFICIENCIAS ===============
-- Averías o fallas detectadas fuera del mantenimiento planificado.
-- Número consecutivo por barco y por año (2026-001, 2026-002...), asignado por el trigger mant_deficiencias_numerar.
CREATE TABLE public.mant_deficiencias (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  anio INT NOT NULL,                        -- lo completa el trigger (año de fecha_detectada)
  numero INT NOT NULL,                      -- lo completa el trigger (último del barco y del año + 1)
  equipo_id INT NOT NULL,                   -- equipo del mismo barco (FK compuesta abajo)
  descripcion TEXT NOT NULL,
  fecha_detectada DATE NOT NULL DEFAULT current_date,
  detectada_por TEXT,
  critica BOOLEAN NOT NULL DEFAULT false,
  fecha_limite DATE NOT NULL,               -- la app propone +7 días si es crítica, +60 si no
  estado TEXT NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta', 'cerrada')),
  fecha_cierre DATE,
  accion_realizada TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_deficiencias_barco_anio_numero_key UNIQUE (barco_id, anio, numero),
  CONSTRAINT mant_deficiencias_equipo_id_fkey FOREIGN KEY (barco_id, equipo_id)
    REFERENCES public.mant_equipos(barco_id, id),
  CHECK (estado = 'abierta' OR (fecha_cierre IS NOT NULL AND accion_realizada IS NOT NULL))
);

-- =============== TRIPULANTES ===============
-- Tripulación del barco. No se borran: se marcan activo = false (la app oculta sus documentos).
CREATE TABLE public.mant_tripulantes (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  nombre TEXT NOT NULL,
  cargo TEXT,
  departamento TEXT NOT NULL CHECK (departamento IN ('Cubierta', 'Máquinas')),  -- lo heredan sus documentos
  activo BOOLEAN NOT NULL DEFAULT true,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_tripulantes_barco_id_id_key UNIQUE (barco_id, id)
);

-- =============== CERTIFICADOS ===============
-- Certificados del barco y documentos personales de la tripulación, con sus vencimientos.
-- No se borran: se marcan activo = false.
-- Las categorías también están en la constante CATEGORIAS_CERT de index.html.
-- Con tripulante_id es un documento personal (categoría 'Tripulación'); sin él, es del barco.
CREATE TABLE public.mant_certificados (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  nombre TEXT NOT NULL,
  categoria TEXT NOT NULL CONSTRAINT mant_certificados_categoria_check
    CHECK (categoria IN ('Seguridad contra incendios', 'Navegabilidad', 'Comunicaciones', 'Salvavidas', 'Pirotecnia', 'Otros', 'Tripulación')),
  tripulante_id BIGINT,                     -- tripulante del mismo barco (FK compuesta abajo)
  departamento TEXT NOT NULL CHECK (departamento IN ('Cubierta', 'Máquinas')),  -- en documentos personales, el del tripulante (trigger)
  fecha_vencimiento DATE NOT NULL,
  dias_aviso INTEGER NOT NULL DEFAULT 30 CHECK (dias_aviso >= 0),
  observaciones TEXT,
  activo BOOLEAN NOT NULL DEFAULT true,
  -- Postergación: mientras postergada_hasta sea hoy o futura, no cuenta en las alertas del Dashboard
  postergada_hasta DATE,
  motivo_postergacion TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_certificados_tripulante_check
    CHECK ((tripulante_id IS NOT NULL) = (categoria = 'Tripulación')),
  CONSTRAINT mant_certificados_postergacion_check
    CHECK ((postergada_hasta IS NULL) = (motivo_postergacion IS NULL)),
  CONSTRAINT mant_certificados_barco_id_id_key UNIQUE (barco_id, id),
  CONSTRAINT mant_certificados_tripulante_id_fkey FOREIGN KEY (barco_id, tripulante_id)
    REFERENCES public.mant_tripulantes(barco_id, id)
);

-- Una fila por renovación; la escribe la función mant_certificados_renovar
CREATE TABLE public.mant_certificados_historial (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  barco_id INTEGER NOT NULL DEFAULT 1 REFERENCES public.mant_buque(id),  -- DEFAULT temporal (Paso 5)
  certificado_id BIGINT NOT NULL,
  fecha_renovacion DATE NOT NULL,
  vencimiento_anterior DATE NOT NULL,
  vencimiento_nuevo DATE NOT NULL,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_certificados_historial_certificado_id_fkey FOREIGN KEY (barco_id, certificado_id)
    REFERENCES public.mant_certificados(barco_id, id)
);

-- =============== ÍNDICES ===============
CREATE INDEX idx_mant_cert_hist_certificado ON public.mant_certificados_historial (certificado_id);
CREATE INDEX idx_mant_certificados_tripulante ON public.mant_certificados (tripulante_id);
CREATE INDEX idx_mant_equipos_categoria ON public.mant_equipos (categoria);
CREATE INDEX idx_mant_equipos_nombre ON public.mant_equipos (nombre);
CREATE INDEX idx_mant_tareas_activa ON public.mant_tareas (activa);
CREATE INDEX idx_mant_tareas_equipo ON public.mant_tareas (equipo);
CREATE INDEX idx_mant_tareas_equipo_id ON public.mant_tareas (equipo_id);
CREATE INDEX idx_mant_historial_fecha ON public.mant_historial (fecha_realizado DESC);
CREATE INDEX idx_mant_historial_tarea ON public.mant_historial (tarea_id);
CREATE INDEX idx_mant_repuestos_categoria ON public.mant_repuestos (categoria);
CREATE INDEX idx_mant_repuestos_subcategoria ON public.mant_repuestos (subcategoria);
CREATE INDEX idx_mant_mov_fecha ON public.mant_movimientos (fecha DESC);
CREATE INDEX idx_mant_mov_repuesto ON public.mant_movimientos (repuesto_id);
CREATE INDEX idx_mant_tarea_rep_repuesto ON public.mant_tarea_repuestos (repuesto_id);
CREATE INDEX idx_mant_tarea_rep_tarea ON public.mant_tarea_repuestos (tarea_id);
CREATE INDEX idx_mant_herr_ubicacion ON public.mant_herramientas (ubicacion);
CREATE INDEX idx_mant_deficiencias_equipo ON public.mant_deficiencias (equipo_id);
CREATE INDEX idx_mant_mov_tarea ON public.mant_movimientos (tarea_id);
-- Por barco (en mant_equipos, mant_tareas, mant_repuestos, mant_tripulantes, mant_certificados y
-- mant_deficiencias también sirven los UNIQUE que empiezan por barco_id)
CREATE INDEX idx_mant_tareas_barco_equipo ON public.mant_tareas (barco_id, equipo_id);
CREATE INDEX idx_mant_historial_barco_tarea ON public.mant_historial (barco_id, tarea_id);
CREATE INDEX idx_mant_mov_barco_repuesto ON public.mant_movimientos (barco_id, repuesto_id);
CREATE INDEX idx_mant_mov_barco_tarea ON public.mant_movimientos (barco_id, tarea_id);
CREATE INDEX idx_mant_tarea_rep_barco_tarea ON public.mant_tarea_repuestos (barco_id, tarea_id);
CREATE INDEX idx_mant_tarea_rep_barco_repuesto ON public.mant_tarea_repuestos (barco_id, repuesto_id);
CREATE INDEX idx_mant_herr_barco ON public.mant_herramientas (barco_id);
CREATE INDEX idx_mant_lecturas_barco ON public.mant_lecturas_horas (barco_id);
CREATE INDEX idx_mant_deficiencias_barco_equipo ON public.mant_deficiencias (barco_id, equipo_id);
CREATE INDEX idx_mant_certificados_barco_trip ON public.mant_certificados (barco_id, tripulante_id);
CREATE INDEX idx_mant_cert_hist_barco_cert ON public.mant_certificados_historial (barco_id, certificado_id);

-- =============== FUNCIONES Y TRIGGERS ===============
-- Fecha de última modificación (mant_tareas usa "actualizada_en"; el resto "actualizado_en")
CREATE OR REPLACE FUNCTION public.mant_update_timestamp()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.actualizada_en = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.mant_update_timestamp_masc()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.actualizado_en = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER mant_tareas_update_timestamp BEFORE UPDATE ON public.mant_tareas
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp();
CREATE TRIGGER trg_mant_buque_upd BEFORE UPDATE ON public.mant_buque
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp_masc();
CREATE TRIGGER trg_mant_equipos_upd BEFORE UPDATE ON public.mant_equipos
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp_masc();
CREATE TRIGGER mant_herramientas_update_timestamp BEFORE UPDATE ON public.mant_herramientas
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp_masc();
CREATE TRIGGER mant_repuestos_update_timestamp BEFORE UPDATE ON public.mant_repuestos
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp_masc();
CREATE TRIGGER trg_mant_certificados_upd BEFORE UPDATE ON public.mant_certificados
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp_masc();
CREATE TRIGGER trg_mant_tripulantes_upd BEFORE UPDATE ON public.mant_tripulantes
  FOR EACH ROW EXECUTE FUNCTION public.mant_update_timestamp_masc();

-- El departamento de un documento personal es siempre el de su tripulante
-- (la FK compuesta garantiza que el tripulante es del mismo barco que el documento)
CREATE OR REPLACE FUNCTION public.mant_certificados_depto_tripulante()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.tripulante_id IS NOT NULL THEN
    SELECT departamento INTO NEW.departamento
      FROM public.mant_tripulantes WHERE id = NEW.tripulante_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER mant_certificados_depto_tripulante
  BEFORE INSERT OR UPDATE OF tripulante_id, departamento ON public.mant_certificados
  FOR EACH ROW EXECUTE FUNCTION public.mant_certificados_depto_tripulante();

-- Si cambia el departamento de un tripulante, se copia a sus documentos (del mismo barco)
CREATE OR REPLACE FUNCTION public.mant_tripulantes_propagar_depto()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE public.mant_certificados
     SET departamento = NEW.departamento
   WHERE barco_id = NEW.barco_id AND tripulante_id = NEW.id
     AND departamento IS DISTINCT FROM NEW.departamento;
  RETURN NEW;
END;
$$;

CREATE TRIGGER mant_tripulantes_propagar_depto
  AFTER UPDATE OF departamento ON public.mant_tripulantes
  FOR EACH ROW EXECUTE FUNCTION public.mant_tripulantes_propagar_depto();

REVOKE EXECUTE ON FUNCTION public.mant_certificados_depto_tripulante() FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.mant_tripulantes_propagar_depto() FROM public, anon;

-- Renovación atómica de un certificado: guarda el historial y actualiza el vencimiento en la misma
-- transacción. El vencimiento anterior se toma de la fila guardada. SECURITY INVOKER: RLS aplica.
-- Si tenía postergación, la borra y deja el motivo en las notas del historial.
-- El historial se guarda con el barco del certificado (no con el DEFAULT de barco_id).
CREATE OR REPLACE FUNCTION public.mant_certificados_renovar(
  p_id BIGINT,
  p_fecha_renovacion DATE,
  p_vencimiento_nuevo DATE,
  p_notas TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_barco INTEGER;
  v_anterior DATE;
  v_post_hasta DATE;
  v_post_motivo TEXT;
  v_notas TEXT;
BEGIN
  SELECT barco_id, fecha_vencimiento, postergada_hasta, motivo_postergacion
    INTO v_barco, v_anterior, v_post_hasta, v_post_motivo
    FROM public.mant_certificados
   WHERE id = p_id AND activo
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Certificado no encontrado';
  END IF;
  IF p_fecha_renovacion IS NULL OR p_vencimiento_nuevo IS NULL THEN
    RAISE EXCEPTION 'Faltan la fecha de renovación o el nuevo vencimiento';
  END IF;
  -- current_date es UTC (adelantado respecto de Uruguay): nunca rechaza el "hoy" local; el chequeo exacto lo hace la app
  IF p_fecha_renovacion > current_date THEN
    RAISE EXCEPTION 'La fecha de renovación no puede ser posterior a hoy';
  END IF;
  IF p_vencimiento_nuevo <= v_anterior THEN
    RAISE EXCEPTION 'El nuevo vencimiento debe ser posterior al actual (%)', v_anterior;
  END IF;
  v_notas := nullif(trim(p_notas), '');
  IF v_post_hasta IS NOT NULL THEN
    v_notas := concat_ws(' — ', v_notas,
      'Estuvo postergado hasta ' || to_char(v_post_hasta, 'DD/MM/YYYY') || ': ' || v_post_motivo);
  END IF;
  INSERT INTO public.mant_certificados_historial
    (barco_id, certificado_id, fecha_renovacion, vencimiento_anterior, vencimiento_nuevo, notas)
  VALUES (v_barco, p_id, p_fecha_renovacion, v_anterior, p_vencimiento_nuevo, v_notas);
  UPDATE public.mant_certificados
     SET fecha_vencimiento = p_vencimiento_nuevo,
         postergada_hasta = NULL,
         motivo_postergacion = NULL
   WHERE id = p_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.mant_certificados_renovar(BIGINT, DATE, DATE, TEXT) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.mant_certificados_renovar(BIGINT, DATE, DATE, TEXT) TO authenticated;

-- Numeración consecutiva de deficiencias por barco y por año (según fecha_detectada)
CREATE OR REPLACE FUNCTION public.mant_deficiencias_numerar()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.anio := extract(year FROM NEW.fecha_detectada)::int;
  PERFORM pg_advisory_xact_lock(hashtext('mant_deficiencias:' || NEW.barco_id), NEW.anio);
  SELECT coalesce(max(numero), 0) + 1 INTO NEW.numero
    FROM public.mant_deficiencias WHERE barco_id = NEW.barco_id AND anio = NEW.anio;
  RETURN NEW;
END;
$$;

CREATE TRIGGER mant_deficiencias_numerar BEFORE INSERT ON public.mant_deficiencias
  FOR EACH ROW EXECUTE FUNCTION public.mant_deficiencias_numerar();

-- =============== ROW LEVEL SECURITY ===============
-- Política: SOLO el usuario propietario (por email) puede acceder a las tablas mant_*
-- Reemplazá 'tu-email@ejemplo.com' por tu email real de Supabase

ALTER TABLE public.mant_buque ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_equipos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_tareas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_historial ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_repuestos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_movimientos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_tarea_repuestos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_herramientas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_lecturas_horas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_deficiencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_certificados ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_certificados_historial ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_tripulantes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mant_buque_owner" ON public.mant_buque
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_equipos_owner" ON public.mant_equipos
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_tareas_owner" ON public.mant_tareas
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_historial_owner" ON public.mant_historial
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_repuestos_owner" ON public.mant_repuestos
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_movimientos_owner" ON public.mant_movimientos
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_tarea_repuestos_owner" ON public.mant_tarea_repuestos
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_herramientas_owner" ON public.mant_herramientas
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_lecturas_horas_owner" ON public.mant_lecturas_horas
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_deficiencias_owner" ON public.mant_deficiencias
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_certificados_owner" ON public.mant_certificados
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_certificados_historial_owner" ON public.mant_certificados_historial
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

CREATE POLICY "mant_tripulantes_owner" ON public.mant_tripulantes
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');
