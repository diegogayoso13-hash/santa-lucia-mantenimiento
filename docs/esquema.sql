-- Esquema de la base de datos en Supabase
-- Proyecto: B/M Santa Lucía - Plan de Mantenimiento
-- Todas las tablas usan prefijo mant_ y tienen RLS activado

-- =============== TAREAS DE MANTENIMIENTO ===============
CREATE TABLE public.mant_tareas (
  id BIGSERIAL PRIMARY KEY,
  equipo TEXT NOT NULL,
  tarea TEXT NOT NULL,
  periodicidad TEXT,
  unidad TEXT CHECK (unidad IN ('hrs', 'fecha', 'ninguna')) DEFAULT 'hrs',
  hrs_totales NUMERIC DEFAULT 0,
  ult_hrs NUMERIC,
  fecha_ult DATE,
  proxima_hrs NUMERIC,
  proxima_fecha DATE,
  prioridad TEXT CHECK (prioridad IN ('ALTA', 'MEDIA', 'BAJA')) DEFAULT 'MEDIA',
  realizado_por TEXT,
  estado_op TEXT DEFAULT 'Operativo',
  observaciones TEXT,
  activa BOOLEAN DEFAULT true,
  creada_en TIMESTAMPTZ DEFAULT now(),
  actualizada_en TIMESTAMPTZ DEFAULT now()
);

-- =============== HISTORIAL ===============
CREATE TABLE public.mant_historial (
  id BIGSERIAL PRIMARY KEY,
  tarea_id BIGINT NOT NULL REFERENCES public.mant_tareas(id) ON DELETE CASCADE,
  fecha_realizado DATE NOT NULL,
  hrs_equipo NUMERIC,
  realizado_por TEXT,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== REPUESTOS ===============
CREATE TABLE public.mant_repuestos (
  id BIGSERIAL PRIMARY KEY,
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
  actualizado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== MOVIMIENTOS DE STOCK ===============
CREATE TABLE public.mant_movimientos (
  id BIGSERIAL PRIMARY KEY,
  repuesto_id BIGINT NOT NULL REFERENCES public.mant_repuestos(id) ON DELETE CASCADE,
  tipo TEXT NOT NULL CHECK (tipo IN ('entrada', 'salida', 'ajuste')),
  cantidad NUMERIC NOT NULL,
  motivo TEXT,
  tarea_id BIGINT REFERENCES public.mant_tareas(id) ON DELETE SET NULL,
  fecha TIMESTAMPTZ DEFAULT now()
);

-- =============== VÍNCULO TAREA-REPUESTOS ===============
CREATE TABLE public.mant_tarea_repuestos (
  id BIGSERIAL PRIMARY KEY,
  tarea_id BIGINT NOT NULL REFERENCES public.mant_tareas(id) ON DELETE CASCADE,
  repuesto_id BIGINT NOT NULL REFERENCES public.mant_repuestos(id) ON DELETE CASCADE,
  cantidad_usada NUMERIC NOT NULL DEFAULT 1,
  UNIQUE(tarea_id, repuesto_id)
);

-- =============== HERRAMIENTAS ===============
CREATE TABLE public.mant_herramientas (
  id BIGSERIAL PRIMARY KEY,
  nombre TEXT NOT NULL,
  marca TEXT,
  cantidad NUMERIC NOT NULL DEFAULT 1,
  ubicacion TEXT,
  notas TEXT,
  creado_en TIMESTAMPTZ DEFAULT now(),
  actualizado_en TIMESTAMPTZ DEFAULT now()
);

-- =============== ROW LEVEL SECURITY ===============
-- Política: SOLO el usuario propietario (por email) puede acceder a las tablas mant_*
-- Reemplazá 'tu-email@ejemplo.com' por tu email real de Supabase

ALTER TABLE public.mant_tareas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_historial ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_repuestos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_movimientos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_tarea_repuestos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mant_herramientas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mant_tareas_owner" ON public.mant_tareas
  FOR ALL TO authenticated
  USING (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com')
  WITH CHECK (auth.jwt() ->> 'email' = 'tu-email@ejemplo.com');

-- (Repetir el bloque CREATE POLICY para cada tabla mant_*)
