# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-page web app for managing shipboard maintenance on the B/M Santa Lucía (a tugboat), replacing a monthly Excel-sheet workflow. No framework, no build step: the entire app (markup, CSS, JS) lives in `index.html`. Backend is Supabase (Postgres + Auth), loaded via CDN `<script>` tags (`@supabase/supabase-js@2`, `xlsx@0.18.5` for Excel export, `chart.js@4.4.1` for the equipment charts).

## Running / developing

There is no build, bundle, lint, or test tooling in this repo — it's plain HTML/CSS/JS.

- Open `index.html` directly in a browser, or serve the directory with any static server (e.g. `npx serve .`) to avoid `file://` CORS quirks.
- To test against real data you need a Supabase project with the schema below and a user account to log in with (Supabase email/password auth — see `iniciarSesion()`).
- There's no local/mock backend — all reads/writes go straight to the live Supabase project configured by `SUPABASE_URL`/`SUPABASE_KEY` near the top of the `<script>` block in `index.html`.

## Architecture

### Single-file structure

`index.html` is organized top-to-bottom as: `<style>` (all CSS, including the `@media (max-width: 700px)` mobile overrides near the bottom of the stylesheet), then markup (login overlay, header, tab nav, one `<section>` per tab, then modal dialogs), then one big `<script>` block with all the JS. There's no module system — everything is global functions/variables, and `onclick="..."` attributes in the HTML call directly into them. When adding a feature, find the matching section by the `============ SECTION NAME ============` comment banners in the JS rather than searching blindly.

### Data flow

- `cargarTodo()` fetches all tables from Supabase in parallel on login/startup and populates global arrays (`tareas`, `historial`, `repuestos`, `herramientas`, `tareaRepuestos`, `buque`, `equipos`, `lecturas`, `deficiencias`). Only active rows are loaded for `mant_tareas` (`activa = true`) and `mant_equipos` (`activo = true`) — equipment is soft-deleted, never hard-deleted.
- `renderTodo()` re-renders every section from those in-memory arrays. There's no reactive framework: after any mutation (save/delete), code calls `cargarTodo()` again (or manually patches the array + calls the relevant `renderX()`), not a diffing re-render.
- Tab switching (`cambiarTab`) just toggles `.active` on `<section>` elements — all tabs are already in the DOM, nothing is lazy-loaded.

### Maintenance status model

`calcularEstado(t)` is the core rule: a task (`mant_tareas` row) is tracked either by engine hours (`unidad: 'hrs'`, comparing `proxima_hrs` vs `hrs_totales`) or by calendar date (`unidad: 'fecha'`, comparing `proxima_fecha` vs today). Thresholds: `VENCIDO` (overdue) if the difference is ≤ 0, `PROXIMO` (upcoming) if ≤ 100 hrs or ≤ 30 days, otherwise `OK`; `SIN_DATO` if neither field is set. This function is called everywhere status is displayed (dashboard counts, task list, equipment cards) — status is always derived, never stored.

### Hour cascading (Cargar Horas tab)

Monthly hours are entered per top-level equipment. `CAJAS_POR_MP` maps each main engine (`Motor Principal Babor/Estribor`) to its reduction gearbox (`Caja Reductora Babor/Estribor`); when hours are saved for an engine, the paired gearbox silently receives the same hours (`guardarCarga()`), and gearboxes are hidden from the manual entry form (`EQUIPOS_OCULTOS_CARGA`). Saving hours also finds tasks that just became `VENCIDO`/`PROXIMO` as a side effect and prompts the user to confirm which were actually completed (`abrirConfirm`/`aplicarConfirm`) before writing `mant_historial` rows.

Each save also inserts one `mant_lecturas_horas` row per equipment (including the cascaded gearbox) with `horas_mes` (hours added this month) and `hrs_total` (cumulative). Readings are keyed by the equipment **name** (`equipo` text), not by `equipo_id`. They're only read by the "Horas" tab (`renderHoras()`).

### Ship & equipment fichas ("Mi Barco" / "Equipos" tabs)

`mant_buque` (a single row) holds vessel particulars (dimensions, tonnage, registry, engines) rendered by `renderBarco()`. `mant_equipos` holds one row per piece of equipment (engine, generator, compressor, etc.) with free-text technical data, rendered as a grid (`renderEquipos()`) and a detail view (`renderFichaEquipo()`) with Chart.js graphs of hours-over-time and maintenance history (`renderGraficosEquipo()`). Tasks can optionally link to an equipment row via `tarea.equipo_id`, which makes the equipment name clickable to jump to its ficha. Note that tasks also carry the equipment name as free text (`tarea.equipo`), and the Tareas filters, hour cascading and `mant_lecturas_horas` match on that name, not on `equipo_id`.

### Critical equipment

`mant_equipos.critico` (boolean, default false) marks equipment whose failure is a safety risk; it's set with the "Equipo crítico" checkbox in the equipment modal. `esTareaCritica(t)` derives criticality for a task through `t.equipo_id` (it's never stored on the task). Effects: a `⚠️ CRÍTICO` badge in `renderTaskCard()`; in `renderDashboard()` critical tasks sort first within each status (VENCIDO, then PROXIMO) in "Más urgentes", plus a separate "X tareas críticas vencidas" banner; a "Solo críticos" checkbox filter in the Tareas tab (`#filtro-critico`).

### Work type (tipo de trabajo)

`mant_tareas.tipo_trabajo` stores a code from the company maintenance plan; descriptions live only in the JS constant `TIPOS_TRABAJO` (I, IL, O, OH, L, T, R, A, MT, E). The column has a `check` constraint listing the allowed codes — **adding a code means updating both the constraint (migration) and `TIPOS_TRABAJO`**. `llenarSelectoresTipoTrabajo()` fills every `<select class="sel-tipo-trabajo">` plus the Tareas filter (`#filtro-tipo-trabajo`, which also has a "Sin tipo" option). The type is set in the "Agregar tarea" modal and in the "Registrar" modal; there, the normal Guardar also registers a completed maintenance, so `guardarSoloTipo()` exists to change only the type without touching history or dates. Cards show it as a `[R] Reemplazo` badge.

Don't confuse it with `#nt-tipo` in the "Agregar tarea" modal, which is the hours-vs-date control mode (`unidad`), not the work type.

### Deficiencias tab

`mant_deficiencias` is a register of breakdowns/faults found outside planned maintenance (section `============ DEFICIENCIAS ============`):

- **Numbering:** `2026-001` style, consecutive and restarting every year. It's assigned **by the database**, not the client: the `before insert` trigger `mant_deficiencias_numerar()` sets `anio` from the year of `fecha_detectada` and `numero = max(numero) + 1` for that year (with an advisory lock), protected by `unique (anio, numero)`. Insert without `anio`/`numero` and read them back with `.select().single()`. `numeroDef(d)` formats the display string. Because the year defines the number, `fecha_detectada` is read-only when editing.
- **Deadline:** `fecha_limite` defaults to `fecha_detectada` + 7 days if `critica`, else + 60 (`DIAS_LIMITE_DEF`, `defRecalcularLimite()`), recalculated when the date or the critical checkbox changes but editable by hand. Choosing an equipment pre-checks `critica` from `mant_equipos.critico`.
- **Lifecycle:** `estado` is `'abierta'` or `'cerrada'`; closing requires `fecha_cierre` and `accion_realizada` (enforced by a table `check` too). Open ones can be edited; there's intentionally no delete in the UI (traceability, no gaps in numbering). `defVencida(d)` = open and `fecha_limite` before today (the deadline day itself is not overdue).
- **UI:** open first (critical first, then by deadline), closed by most recent close date; tab badge with the open count; Dashboard stat card "Deficiencias abiertas" plus a banner when any are overdue or critical; separate Excel export (`exportarDefExcel()`).
- Loaded with an embed so names survive equipment soft-deletes: `select('*, equipo:mant_equipos(nombre)')`; use `nombreEquipoDef(d)` to display it.

### Dates

Older code computes "today" with `new Date().toISOString().split('T')[0]`, which is UTC and rolls over to tomorrow after 21:00 in Uruguay (UTC-3). New code uses `hoyLocalISO()` and `sumarDias()` (defined in the Deficiencias section); prefer those for new date logic.

### Auth

Supabase email/password auth (`sb.auth`). `chequearSesion()` runs on load; `onAuthStateChange` hides the app back to the login overlay on `SIGNED_OUT`. There is no signup flow in the UI — accounts are provisioned directly in Supabase.

## Database schema

`docs/esquema.sql` documents all ten `mant_*` tables plus their indexes, functions/triggers and RLS policies, matching the live project as of 2026-10-13 (it uses a placeholder owner email). **Keep it in sync**: whenever you apply a migration, update the file too. The live Supabase project is the source of truth if they ever disagree. Tables added beyond the original six:

- `mant_buque` — single row of vessel particulars.
- `mant_equipos` — equipment fichas; includes `activo` (soft delete) and `critico boolean not null default false`.
- `mant_lecturas_horas` — `equipo` (text name), `fecha`, `horas_mes`, `hrs_total`.
- `mant_deficiencias` — `anio`, `numero` (unique together, set by trigger `mant_deficiencias_numerar`), `equipo_id` → `mant_equipos(id)`, `descripcion`, `fecha_detectada`, `detectada_por`, `critica`, `fecha_limite`, `estado` (`'abierta'|'cerrada'`), `fecha_cierre`, `accion_realizada`, `creado_en`.
- `mant_tareas` extra columns: `equipo_id` → `mant_equipos(id)`, `tipo_trabajo` (check-constrained code, nullable). `unidad` also allows `'ninguna'`.

Every `mant_*` table has RLS enabled with a single `<tabla>_owner` policy: `for all to authenticated using/with check ((auth.jwt() ->> 'email') = '<owner email>')`. New `mant_*` tables must copy that policy. Apply schema changes as migrations (`apply_migration`), then run the security advisors. Known pre-existing advisor warnings: `mant_update_timestamp` and `mant_update_timestamp_masc` have a mutable `search_path`.

## Conventions

- UI text, comments, and variable/function names are in Spanish (matching the vessel's crew); keep new code consistent with that.
- No dependency manager — new third-party libs are added as CDN `<script>` tags in `<head>`.
- XSS: any user-supplied string interpolated into `innerHTML` must go through `escape()`.
