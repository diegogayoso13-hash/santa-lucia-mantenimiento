# ⚓ B/M Santa Lucía — Plan de Mantenimiento

Aplicación web para gestionar el mantenimiento de equipos a bordo del B/M Santa Lucía. Reemplaza el sistema viejo de planillas Excel mes a mes con una sola fuente de verdad online.

## ¿Qué hace?

- **Dashboard** con alertas de mantenimientos vencidos o próximos
- **Gestión de tareas** por horas de uso o por fecha
- **Carga rápida de horas** mensuales con detección automática de tareas vencidas
- **Stock de repuestos** agrupado por categoría (Filtros, Motor Principal, Motogenerador, Compresor)
- **Inventario de herramientas** organizado por ubicación
- **Historial completo** de cada mantenimiento realizado
- **Exportación a Excel** de tareas, stock y herramientas

## Tecnologías

- HTML + CSS + JavaScript (sin frameworks ni build)
- [Supabase](https://supabase.com/) como backend (PostgreSQL + Auth)
- [SheetJS](https://sheetjs.com/) para exportar a Excel

## Cómo usarla

1. Cloná este repo
2. Abrí `index.html` en cualquier navegador moderno (Chrome, Edge, Safari, Firefox)
3. Iniciá sesión con tu usuario de Supabase

> Los datos se guardan online en Supabase, así que la app funciona en cualquier dispositivo donde te loguees.

## Estructura

```
.
├── index.html          # La app completa (HTML + CSS + JS en un solo archivo)
├── README.md           # Este archivo
└── docs/
    └── esquema.sql     # Esquema de las tablas en Supabase
```

## Tablas en Supabase

- `mant_tareas` — catálogo de tareas de mantenimiento
- `mant_historial` — registro de cada mantenimiento realizado
- `mant_repuestos` — stock de repuestos consumibles
- `mant_movimientos` — entradas/salidas de stock
- `mant_tarea_repuestos` — qué repuestos consume cada tarea
- `mant_herramientas` — inventario de herramientas

Todas las tablas usan Row Level Security (RLS) y solo permiten acceso a usuarios autenticados.

## Licencia

Uso privado.
