-- Esquema de la base de datos de PRUEBA en Supabase (varios barcos)
-- Proyecto: "Mantenimiento Naval" (ncughlkgdgigwkggnxri), usado por la versión de prueba (prueba/index.html).
-- La base REAL (la que usa index.html de la raíz) sigue documentada en docs/esquema.sql.
-- Todas las tablas usan prefijo mant_ y tienen RLS activado
-- Refleja la base de prueba al 2026-10-29. Si hay dudas, la fuente de verdad es el proyecto en Supabase.
--
-- VARIOS BARCOS:
-- - mant_buque es la tabla de barcos: una fila por barco (id 1 = B/M Santa Lucía).
-- - Todas las demás tablas mant_* tienen barco_id NOT NULL -> mant_buque(id), sin valor por defecto:
--   la app filtra todo por el barco elegido y manda siempre su barco_id al guardar.
-- - Las tablas que tienen hijas tienen UNIQUE (barco_id, id) y las hijas las referencian por (barco_id, x_id),
--   así la base rechaza mezclar barcos (p. ej. una tarea de un barco con un equipo de otro).
--
-- EMPRESAS, USUARIOS Y PERMISOS:
-- - Cada barco pertenece a una empresa (mant_empresas). Los datos de una empresa nunca se ven desde otra.
-- - mant_accesos dice qué usuario (auth.users) tiene qué rol: admin_empresa (toda su empresa, sin barco)
--   o jefe / operador / lectura (por barco). Los usuarios se dan de alta desde el panel (no hay registro libre).
-- - Las reglas RLS de todas las tablas usan funciones de mant_priv (esquema que la API no expone).
-- - Quién hizo cada cosa (creado_por, cerrada_por) lo pone la base con auth.uid(); la app no lo puede falsear.

-- =============== EMPRESAS ===============
-- Se crean desde la base (al sumar un cliente); el admin de la empresa solo puede renombrarla.
CREATE TABLE public.mant_empresas (
  id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre TEXT NOT NULL,
  creado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== BARCOS (mant_buque: una fila por barco) ===============
CREATE TABLE public.mant_buque (
  id SERIAL PRIMARY KEY,
  empresa_id INTEGER NOT NULL REFERENCES public.mant_empresas(id),  -- no se puede cambiar desde la app (trigger)
  nombre TEXT NOT NULL,
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
  actualizado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_buque_empresa_id_id_key UNIQUE (empresa_id, id)
);

-- =============== ACCESOS (usuario -> empresa/barco, con rol) ===============
-- admin_empresa: sin barco, cubre todos los barcos de su empresa (también los que se agreguen).
-- jefe / operador / lectura: por barco. Un solo rol por usuario y barco.
CREATE TABLE public.mant_accesos (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  empresa_id INTEGER NOT NULL REFERENCES public.mant_empresas(id),
  barco_id INTEGER,
  rol TEXT NOT NULL CONSTRAINT mant_accesos_rol_check
    CHECK (rol IN ('admin_empresa', 'jefe', 'operador', 'lectura')),
  creado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_accesos_barco_rol_check CHECK ((rol = 'admin_empresa') = (barco_id IS NULL)),
  -- el barco tiene que ser de esa empresa
  CONSTRAINT mant_accesos_barco_id_fkey FOREIGN KEY (empresa_id, barco_id)
    REFERENCES public.mant_buque(empresa_id, id) ON DELETE CASCADE,
  CONSTRAINT mant_accesos_unico UNIQUE NULLS NOT DISTINCT (user_id, empresa_id, barco_id)
);

-- =============== EQUIPOS (fichas) ===============
-- Los equipos no se borran: se marcan activo = false.
CREATE TABLE public.mant_equipos (
  id SERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  -- "Toma las horas de": equipo sin horómetro propio (p. ej. una caja reductora) que recibe las mismas horas
  -- que otro del mismo barco cuando se cargan las horas de ese. Sin círculos (trigger mant_equipos_horas_sin_circulo).
  horas_de_id INTEGER,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_equipos_barco_id_id_key UNIQUE (barco_id, id),
  CONSTRAINT mant_equipos_horas_de_fkey FOREIGN KEY (barco_id, horas_de_id)
    REFERENCES public.mant_equipos(barco_id, id) ON DELETE SET NULL (horas_de_id),  -- solo del mismo barco
  CONSTRAINT mant_equipos_horas_de_propio_check CHECK (horas_de_id IS NULL OR horas_de_id <> id)
);

-- =============== TAREAS DE MANTENIMIENTO ===============
CREATE TABLE public.mant_tareas (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
  tarea_id BIGINT NOT NULL,
  fecha_realizado DATE NOT NULL,
  hrs_equipo NUMERIC,
  realizado_por TEXT,
  notas TEXT,
  creado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- lo pone la base (auth.uid())
  creado_en TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_historial_tarea_id_fkey FOREIGN KEY (barco_id, tarea_id)
    REFERENCES public.mant_tareas(barco_id, id) ON DELETE CASCADE
);

-- =============== REPUESTOS ===============
CREATE TABLE public.mant_repuestos (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
  repuesto_id BIGINT NOT NULL,
  tipo TEXT NOT NULL CHECK (tipo IN ('entrada', 'salida', 'ajuste')),
  cantidad NUMERIC NOT NULL,
  motivo TEXT,
  tarea_id BIGINT,
  creado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- lo pone la base (auth.uid())
  fecha TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT mant_movimientos_repuesto_id_fkey FOREIGN KEY (barco_id, repuesto_id)
    REFERENCES public.mant_repuestos(barco_id, id) ON DELETE CASCADE,
  CONSTRAINT mant_movimientos_tarea_id_fkey FOREIGN KEY (barco_id, tarea_id)
    REFERENCES public.mant_tareas(barco_id, id) ON DELETE SET NULL (tarea_id)
);

-- =============== VÍNCULO TAREA-REPUESTOS ===============
CREATE TABLE public.mant_tarea_repuestos (
  id BIGSERIAL PRIMARY KEY,
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
  equipo TEXT NOT NULL,
  fecha DATE NOT NULL,
  horas_mes NUMERIC,                        -- horas sumadas en el mes
  hrs_total NUMERIC,                        -- horas acumuladas del equipo
  creado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- lo pone la base (auth.uid())
  creado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== DEFICIENCIAS ===============
-- Averías o fallas detectadas fuera del mantenimiento planificado.
-- Número consecutivo por barco y por año (2026-001, 2026-002...), asignado por el trigger mant_deficiencias_numerar.
CREATE TABLE public.mant_deficiencias (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  creado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- lo pone la base (auth.uid())
  cerrada_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- quién la cerró (lo pone la base)
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
  barco_id INTEGER NOT NULL REFERENCES public.mant_buque(id),
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
CREATE INDEX idx_mant_equipos_barco_horas_de ON public.mant_equipos (barco_id, horas_de_id);
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
-- Accesos (user_id ya está cubierto por mant_accesos_unico) y autores
CREATE INDEX idx_mant_accesos_empresa_barco ON public.mant_accesos (empresa_id, barco_id);
CREATE INDEX idx_mant_historial_creado_por ON public.mant_historial (creado_por);
CREATE INDEX idx_mant_lecturas_creado_por ON public.mant_lecturas_horas (creado_por);
CREATE INDEX idx_mant_mov_creado_por ON public.mant_movimientos (creado_por);
CREATE INDEX idx_mant_deficiencias_creado_por ON public.mant_deficiencias (creado_por);
CREATE INDEX idx_mant_deficiencias_cerrada_por ON public.mant_deficiencias (cerrada_por);

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

-- =============== PERMISOS: FUNCIONES AUXILIARES (esquema mant_priv) ===============
-- mant_priv no está expuesto por la API. Las funciones son SECURITY DEFINER: leen mant_accesos sin pasar por RLS.
-- Niveles: 1 lectura, 2 operador, 3 jefe, 4 admin_empresa (admin_empresa cubre todos los barcos de su empresa).
CREATE SCHEMA mant_priv;
REVOKE ALL ON SCHEMA mant_priv FROM public;
GRANT USAGE ON SCHEMA mant_priv TO authenticated, service_role;

CREATE FUNCTION mant_priv.nivel_rol(p_rol TEXT) RETURNS INTEGER
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_rol WHEN 'admin_empresa' THEN 4 WHEN 'jefe' THEN 3 WHEN 'operador' THEN 2 WHEN 'lectura' THEN 1 ELSE 0 END;
$$;

-- Barcos donde el usuario actual tiene al menos ese nivel
CREATE FUNCTION mant_priv.barcos(p_nivel INTEGER) RETURNS INTEGER[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT x.id), '{}') FROM (
    SELECT a.barco_id AS id
      FROM public.mant_accesos a
     WHERE a.user_id = auth.uid() AND a.barco_id IS NOT NULL
       AND mant_priv.nivel_rol(a.rol) >= p_nivel
    UNION
    SELECT b.id
      FROM public.mant_accesos a
      JOIN public.mant_buque b ON b.empresa_id = a.empresa_id
     WHERE a.user_id = auth.uid() AND a.rol = 'admin_empresa'
  ) x;
$$;

-- Empresas donde el usuario tiene algún acceso / donde es admin
CREATE FUNCTION mant_priv.empresas() RETURNS INTEGER[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT a.empresa_id), '{}') FROM public.mant_accesos a WHERE a.user_id = auth.uid();
$$;
CREATE FUNCTION mant_priv.empresas_admin() RETURNS INTEGER[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(array_agg(DISTINCT a.empresa_id), '{}') FROM public.mant_accesos a
   WHERE a.user_id = auth.uid() AND a.rol = 'admin_empresa';
$$;

-- Nivel del usuario actual en un barco (lo usan los triggers de control)
CREATE FUNCTION mant_priv.nivel(p_barco INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(max(mant_priv.nivel_rol(a.rol)), 0)
    FROM public.mant_accesos a
   WHERE a.user_id = auth.uid()
     AND (a.barco_id = p_barco
          OR (a.rol = 'admin_empresa'
              AND a.empresa_id = (SELECT b.empresa_id FROM public.mant_buque b WHERE b.id = p_barco)));
$$;

-- =============== PERMISOS: TRIGGERS DE AUTOR Y DE CONTROL ===============
-- Todos se saltean cuando no hay usuario de la app (auth.uid() nulo: SQL directo o panel de Supabase).

-- Autor de historial, lecturas de horas y movimientos: siempre el usuario de la sesión, y no se cambia después
CREATE FUNCTION mant_priv.registrar_autor() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.creado_por := auth.uid();
  ELSE
    NEW.creado_por := OLD.creado_por;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mant_historial_autor BEFORE INSERT OR UPDATE ON public.mant_historial
  FOR EACH ROW EXECUTE FUNCTION mant_priv.registrar_autor();
CREATE TRIGGER mant_lecturas_horas_autor BEFORE INSERT OR UPDATE ON public.mant_lecturas_horas
  FOR EACH ROW EXECUTE FUNCTION mant_priv.registrar_autor();
CREATE TRIGGER mant_movimientos_autor BEFORE INSERT OR UPDATE ON public.mant_movimientos
  FOR EACH ROW EXECUTE FUNCTION mant_priv.registrar_autor();

-- Deficiencias: autor, quién la cerró (se borra al reabrir) y anio/numero fijos
CREATE FUNCTION mant_priv.deficiencias_autor() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.creado_por := auth.uid();
    NEW.cerrada_por := CASE WHEN NEW.estado = 'cerrada' THEN auth.uid() END;
  ELSE
    IF (NEW.anio, NEW.numero) IS DISTINCT FROM (OLD.anio, OLD.numero) THEN
      RAISE EXCEPTION 'El número de la deficiencia no se puede cambiar' USING ERRCODE = '42501';
    END IF;
    NEW.creado_por := OLD.creado_por;
    IF NEW.estado = 'cerrada' AND OLD.estado = 'abierta' THEN
      NEW.cerrada_por := auth.uid();
    ELSIF NEW.estado = 'abierta' THEN
      NEW.cerrada_por := NULL;
    ELSE
      NEW.cerrada_por := OLD.cerrada_por;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mant_deficiencias_autor BEFORE INSERT OR UPDATE ON public.mant_deficiencias
  FOR EACH ROW EXECUTE FUNCTION mant_priv.deficiencias_autor();

-- El operador (nivel < jefe) solo cambia el "estado" de una tarea al registrar o cargar horas, no el plan,
-- y puede quitar una postergación al registrar pero no postergar
CREATE FUNCTION mant_priv.tareas_control_operador() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_libres TEXT[] := ARRAY['fecha_ult', 'ult_hrs', 'hrs_totales', 'proxima_hrs', 'proxima_fecha', 'realizado_por',
                           'observaciones', 'postergada_hasta', 'motivo_postergacion', 'actualizada_en'];
BEGIN
  IF auth.uid() IS NULL OR mant_priv.nivel(OLD.barco_id) >= 3 THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - v_libres) IS DISTINCT FROM (to_jsonb(OLD) - v_libres) THEN
    RAISE EXCEPTION 'Sin permiso para cambiar el plan de la tarea' USING ERRCODE = '42501';
  END IF;
  IF NEW.postergada_hasta IS NOT NULL
     AND (NEW.postergada_hasta, NEW.motivo_postergacion) IS DISTINCT FROM (OLD.postergada_hasta, OLD.motivo_postergacion) THEN
    RAISE EXCEPTION 'Sin permiso para postergar tareas' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mant_tareas_control_operador BEFORE UPDATE ON public.mant_tareas
  FOR EACH ROW EXECUTE FUNCTION mant_priv.tareas_control_operador();

-- El operador solo cambia la cantidad de un repuesto (movimientos de stock)
CREATE FUNCTION mant_priv.repuestos_control_operador() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_libres TEXT[] := ARRAY['cantidad', 'actualizado_en'];
BEGIN
  IF auth.uid() IS NULL OR mant_priv.nivel(OLD.barco_id) >= 3 THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - v_libres) IS DISTINCT FROM (to_jsonb(OLD) - v_libres) THEN
    RAISE EXCEPTION 'Sin permiso para cambiar el repuesto (solo la cantidad)' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mant_repuestos_control_operador BEFORE UPDATE ON public.mant_repuestos
  FOR EACH ROW EXECUTE FUNCTION mant_priv.repuestos_control_operador();

-- Un barco no se puede pasar a otra empresa desde la app
CREATE FUNCTION mant_priv.buque_empresa_fija() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NEW.empresa_id IS DISTINCT FROM OLD.empresa_id THEN
    RAISE EXCEPTION 'El barco no se puede pasar a otra empresa' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mant_buque_empresa_fija BEFORE UPDATE ON public.mant_buque
  FOR EACH ROW EXECUTE FUNCTION mant_priv.buque_empresa_fija();

-- "Toma las horas de" sin círculos: siguiendo la cadena desde el equipo elegido nunca se vuelve a este
CREATE FUNCTION mant_priv.equipos_horas_sin_circulo() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.horas_de_id IS NULL THEN RETURN NEW; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('mant_equipos_horas_de'), NEW.barco_id);
  IF EXISTS (
    WITH RECURSIVE cadena (id, paso) AS (
      SELECT e.horas_de_id, 1 FROM public.mant_equipos e WHERE e.id = NEW.horas_de_id
      UNION ALL
      SELECT e.horas_de_id, c.paso + 1
        FROM public.mant_equipos e JOIN cadena c ON e.id = c.id
       WHERE c.id IS NOT NULL AND c.id <> NEW.id AND c.paso < 1000
    )
    SELECT 1 FROM cadena WHERE id = NEW.id
  ) THEN
    RAISE EXCEPTION 'Círculo en "Toma las horas de": ese equipo ya toma (directa o indirectamente) las horas de este'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mant_equipos_horas_sin_circulo BEFORE INSERT OR UPDATE OF horas_de_id ON public.mant_equipos
  FOR EACH ROW EXECUTE FUNCTION mant_priv.equipos_horas_sin_circulo();

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA mant_priv FROM public;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA mant_priv TO authenticated, service_role;

-- =============== ROW LEVEL SECURITY ===============
-- Todo es "TO authenticated": sin sesión (anon) no hay ninguna política ni permisos sobre las tablas.
-- mant_priv.barcos(n) va en un subselect con cast, así Postgres lo calcula una sola vez por consulta.
-- Por tabla: ver / agregar / modificar / borrar, con el nivel mínimo (1 lectura, 2 operador, 3 jefe):
--
--   tabla                          ver agregar modificar borrar
--   mant_equipos                    1     3        3       3
--   mant_herramientas               1     3        3       3
--   mant_tripulantes                1     3        3       3
--   mant_certificados               1     3        3       3
--   mant_certificados_historial     1     3        3       3   (lo escribe mant_certificados_renovar)
--   mant_tarea_repuestos            1     3        3       3
--   mant_tareas                     1     3        2       3   (el operador solo el estado: trigger)
--   mant_repuestos                  1     3        2       3   (el operador solo la cantidad: trigger)
--   mant_historial                  1     2        3       3
--   mant_lecturas_horas             1     2        3       3
--   mant_movimientos                1     2        3       3
--
-- Las once se crean así (<tabla>, <v>, <a>, <m>, <b> según la tabla de arriba):
--   CREATE POLICY <tabla>_ver ON public.<tabla> FOR SELECT TO authenticated
--     USING (barco_id = ANY ((SELECT mant_priv.barcos(<v>))::INTEGER[]));
--   CREATE POLICY <tabla>_agregar ON public.<tabla> FOR INSERT TO authenticated
--     WITH CHECK (barco_id = ANY ((SELECT mant_priv.barcos(<a>))::INTEGER[]));
--   CREATE POLICY <tabla>_modificar ON public.<tabla> FOR UPDATE TO authenticated
--     USING (barco_id = ANY ((SELECT mant_priv.barcos(<m>))::INTEGER[]))
--     WITH CHECK (barco_id = ANY ((SELECT mant_priv.barcos(<m>))::INTEGER[]));
--   CREATE POLICY <tabla>_borrar ON public.<tabla> FOR DELETE TO authenticated
--     USING (barco_id = ANY ((SELECT mant_priv.barcos(<b>))::INTEGER[]));

ALTER TABLE public.mant_empresas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_buque ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_accesos ENABLE ROW LEVEL SECURITY;
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

DO $$
DECLARE g RECORD;
BEGIN
  FOR g IN SELECT * FROM (VALUES
    ('mant_equipos',                1, 3, 3, 3),
    ('mant_herramientas',           1, 3, 3, 3),
    ('mant_tripulantes',            1, 3, 3, 3),
    ('mant_certificados',           1, 3, 3, 3),
    ('mant_certificados_historial', 1, 3, 3, 3),
    ('mant_tarea_repuestos',        1, 3, 3, 3),
    ('mant_tareas',                 1, 3, 2, 3),
    ('mant_repuestos',              1, 3, 2, 3),
    ('mant_historial',              1, 2, 3, 3),
    ('mant_lecturas_horas',         1, 2, 3, 3),
    ('mant_movimientos',            1, 2, 3, 3)
  ) v(tabla, ver, agregar, modificar, borrar) LOOP
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (barco_id = ANY ((SELECT mant_priv.barcos(%s))::INTEGER[]))',
                   g.tabla || '_ver', g.tabla, g.ver);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (barco_id = ANY ((SELECT mant_priv.barcos(%s))::INTEGER[]))',
                   g.tabla || '_agregar', g.tabla, g.agregar);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (barco_id = ANY ((SELECT mant_priv.barcos(%s))::INTEGER[])) WITH CHECK (barco_id = ANY ((SELECT mant_priv.barcos(%s))::INTEGER[]))',
                   g.tabla || '_modificar', g.tabla, g.modificar, g.modificar);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (barco_id = ANY ((SELECT mant_priv.barcos(%s))::INTEGER[]))',
                   g.tabla || '_borrar', g.tabla, g.borrar);
  END LOOP;
END $$;

-- Deficiencias: el operador crea, edita y cierra las abiertas; las cerradas solo las cambia jefe/admin
CREATE POLICY mant_deficiencias_ver ON public.mant_deficiencias FOR SELECT TO authenticated
  USING (barco_id = ANY ((SELECT mant_priv.barcos(1))::INTEGER[]));
CREATE POLICY mant_deficiencias_agregar ON public.mant_deficiencias FOR INSERT TO authenticated
  WITH CHECK (barco_id = ANY ((SELECT mant_priv.barcos(2))::INTEGER[]));
CREATE POLICY mant_deficiencias_modificar ON public.mant_deficiencias FOR UPDATE TO authenticated
  USING (barco_id = ANY ((SELECT mant_priv.barcos(3))::INTEGER[])
         OR (estado = 'abierta' AND barco_id = ANY ((SELECT mant_priv.barcos(2))::INTEGER[])))
  WITH CHECK (barco_id = ANY ((SELECT mant_priv.barcos(2))::INTEGER[]));
CREATE POLICY mant_deficiencias_borrar ON public.mant_deficiencias FOR DELETE TO authenticated
  USING (barco_id = ANY ((SELECT mant_priv.barcos(3))::INTEGER[]));

-- Barcos: ver los propios (el admin, todos los de su empresa, también el que acaba de crear);
-- editar la ficha el jefe; crear barcos el admin en su empresa; borrar, nadie desde la app
CREATE POLICY mant_buque_ver ON public.mant_buque FOR SELECT TO authenticated
  USING (id = ANY ((SELECT mant_priv.barcos(1))::INTEGER[])
         OR empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]));
CREATE POLICY mant_buque_agregar ON public.mant_buque FOR INSERT TO authenticated
  WITH CHECK (empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]));
CREATE POLICY mant_buque_modificar ON public.mant_buque FOR UPDATE TO authenticated
  USING (id = ANY ((SELECT mant_priv.barcos(3))::INTEGER[]))
  WITH CHECK (id = ANY ((SELECT mant_priv.barcos(3))::INTEGER[]));

-- Empresas: ver la propia; el admin la renombra; crear y borrar solo desde la base
CREATE POLICY mant_empresas_ver ON public.mant_empresas FOR SELECT TO authenticated
  USING (id = ANY ((SELECT mant_priv.empresas())::INTEGER[]));
CREATE POLICY mant_empresas_modificar ON public.mant_empresas FOR UPDATE TO authenticated
  USING (id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]))
  WITH CHECK (id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]));

-- Accesos: cada uno ve los suyos; el admin ve y administra los de su empresa, menos el propio
-- (así nadie se sube el rol ni se deja afuera por error)
CREATE POLICY mant_accesos_ver ON public.mant_accesos FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]));
CREATE POLICY mant_accesos_agregar ON public.mant_accesos FOR INSERT TO authenticated
  WITH CHECK (empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]) AND user_id <> (SELECT auth.uid()));
CREATE POLICY mant_accesos_modificar ON public.mant_accesos FOR UPDATE TO authenticated
  USING (empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]) AND user_id <> (SELECT auth.uid()))
  WITH CHECK (empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]) AND user_id <> (SELECT auth.uid()));
CREATE POLICY mant_accesos_borrar ON public.mant_accesos FOR DELETE TO authenticated
  USING (empresa_id = ANY ((SELECT mant_priv.empresas_admin())::INTEGER[]) AND user_id <> (SELECT auth.uid()));

-- Permisos de tabla: anon no tiene ninguno; authenticated, los cuatro (RLS decide)
REVOKE ALL ON public.mant_empresas, public.mant_accesos FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.mant_empresas, public.mant_accesos TO authenticated;
