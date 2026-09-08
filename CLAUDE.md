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

- `cargarTodo()` fetches all tables from Supabase in parallel on login/startup and populates global arrays (`tareas`, `historial`, `repuestos`, `herramientas`, `tareaRepuestos`, `buque`, `equipos`, `lecturas`).
- `renderTodo()` re-renders every section from those in-memory arrays. There's no reactive framework: after any mutation (save/delete), code calls `cargarTodo()` again (or manually patches the array + calls the relevant `renderX()`), not a diffing re-render.
- Tab switching (`cambiarTab`) just toggles `.active` on `<section>` elements — all tabs are already in the DOM, nothing is lazy-loaded.

### Maintenance status model

`calcularEstado(t)` is the core rule: a task (`mant_tareas` row) is tracked either by engine hours (`unidad: 'hrs'`, comparing `proxima_hrs` vs `hrs_totales`) or by calendar date (`unidad: 'fecha'`, comparing `proxima_fecha` vs today). Thresholds: `VENCIDO` (overdue) if the difference is ≤ 0, `PROXIMO` (upcoming) if ≤ 100 hrs or ≤ 30 days, otherwise `OK`; `SIN_DATO` if neither field is set. This function is called everywhere status is displayed (dashboard counts, task list, equipment cards) — status is always derived, never stored.

### Hour cascading (Cargar Horas tab)

Monthly hours are entered per top-level equipment. `CAJAS_POR_MP` maps each main engine (`Motor Principal Babor/Estribor`) to its reduction gearbox (`Caja Reductora Babor/Estribor`); when hours are saved for an engine, the paired gearbox silently receives the same hours (`guardarCarga()`), and gearboxes are hidden from the manual entry form (`EQUIPOS_OCULTOS_CARGA`). Saving hours also finds tasks that just became `VENCIDO`/`PROXIMO` as a side effect and prompts the user to confirm which were actually completed (`abrirConfirm`/`aplicarConfirm`) before writing `mant_historial` rows.

### Ship & equipment fichas ("Mi Barco" / "Equipos" tabs)

`mant_buque` (a single row) holds vessel particulars (dimensions, tonnage, registry, engines) rendered by `renderBarco()`. `mant_equipos` holds one row per piece of equipment (engine, generator, compressor, etc.) with free-text technical data, rendered as a grid (`renderEquipos()`) and a detail view (`renderFichaEquipo()`) with Chart.js graphs of hours-over-time and maintenance history (`renderGraficosEquipo()`). Tasks can optionally link to an equipment row via `tarea.equipo_id`, which makes the equipment name clickable to jump to its ficha.

### Auth

Supabase email/password auth (`sb.auth`). `chequearSesion()` runs on load; `onAuthStateChange` hides the app back to the login overlay on `SIGNED_OUT`. There is no signup flow in the UI — accounts are provisioned directly in Supabase.

## Database schema

`docs/esquema.sql` documents the original `mant_*` tables (`mant_tareas`, `mant_historial`, `mant_repuestos`, `mant_movimientos`, `mant_tarea_repuestos`, `mant_herramientas`) with RLS restricting access to one owner email via `auth.jwt() ->> 'email'`.

**Note:** the app code also reads/writes `mant_buque`, `mant_equipos`, and `mant_lecturas_horas` (see `cargarTodo()` in `index.html`), which are not defined in `docs/esquema.sql`. If you need their schema, check the live Supabase project directly (via the Supabase MCP tools) rather than trusting the SQL file alone — it's out of date relative to the app.

## Conventions

- UI text, comments, and variable/function names are in Spanish (matching the vessel's crew); keep new code consistent with that.
- No dependency manager — new third-party libs are added as CDN `<script>` tags in `<head>`.
- XSS: any user-supplied string interpolated into `innerHTML` must go through `escape()`.
