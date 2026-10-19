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

- `cargarTodo()` fetches all tables from Supabase in parallel on login/startup and populates global arrays (`tareas`, `historial`, `repuestos`, `herramientas`, `tareaRepuestos`, `buque`, `equipos`, `lecturas`, `deficiencias`, `certificados`, `certHistorial`, `tripulantes`). Only active rows are loaded for `mant_tareas` (`activa = true`), `mant_equipos` and `mant_certificados` (`activo = true`) — equipment, certificates and crew are soft-deleted, never hard-deleted. `tripulantes` is loaded in full (including inactive), and `certificados` drops the documents of inactive crew members right after loading.
- `renderTodo()` re-renders every section from those in-memory arrays. There's no reactive framework: after any mutation (save/delete), code calls `cargarTodo()` again (or manually patches the array + calls the relevant `renderX()`), not a diffing re-render.
- Tab switching (`cambiarTab`) just toggles `.active` on `<section>` elements — all tabs are already in the DOM, nothing is lazy-loaded.

### Navigation (two levels)

The top bar has four sections, each with its sub-tabs underneath:

| Section | Sub-tabs |
|---|---|
| 📊 Inicio | Dashboard |
| 🔧 Mantenimiento | Tareas, Deficiencias, Horas, Historial |
| ⚓ Barco | Mi Barco, Equipos, Certificados |
| 📦 Pañol | Stock, Herramientas |

- **Markup:** each sub-tab is a `.tab` button with `data-tab` (opens `<section id="sec-<tab>">`) and `data-seccion`. `SECCION_DE_TAB` is built from those attributes, so **a new tab only needs its button and section**.
- **Navigating:** always call `cambiarTab('<sub-tab>')`. It activates the section too, shows only that section's sub-tabs, and hides the sub-tab row when the section has a single sub-tab.
  - Clicking a section (`cambiarSeccion()`) reopens the last sub-tab used in it.
  - The current tab and the last sub-tab per section are saved in `localStorage` (key `nav`) and restored on load.
- **Section badges** (`#badge-sec-*`) are the sum of the visible sub-tab badges, recomputed by a `MutationObserver` whenever any sub-tab badge changes. The code that sets the sub-tab badges never touches them.
- On mobile the four sections share the width (icon above the label) and the sub-tab row scrolls horizontally.

### Maintenance status model

`calcularEstado(t)` is the core rule: a task (`mant_tareas` row) is tracked either by engine hours (`unidad: 'hrs'`, comparing `proxima_hrs` vs `hrs_totales`) or by calendar date (`unidad: 'fecha'`, comparing `proxima_fecha` vs today). Thresholds: `VENCIDO` (overdue) if the difference is ≤ 0, `PROXIMO` (upcoming) if ≤ 100 hrs or ≤ 30 days, otherwise `OK`; `SIN_DATO` if neither field is set. This function is called everywhere status is displayed (dashboard counts, task list, equipment cards) — status is always derived, never stored.

### Hour cascading (Horas tab)

The "Horas" sub-tab (`sec-horas`) has the monthly hours entry on top (`renderCarga()`) and the per-equipment history below (`renderHoras()`). "Chequeos por fecha" — registering several date-based tasks at once (`renderChequeosFecha()` / `aplicarChequeos()`) — lives in the `#modal-chequeos` modal, opened by "✓ Registrar varias" in the Tareas tab; it closes itself after a successful apply.

Monthly hours are entered per top-level equipment. `CAJAS_POR_MP` maps each main engine (`Motor Principal Babor/Estribor`) to its reduction gearbox (`Caja Reductora Babor/Estribor`); when hours are saved for an engine, the paired gearbox silently receives the same hours (`guardarCarga()`), and gearboxes are hidden from the manual entry form (`EQUIPOS_OCULTOS_CARGA`). Saving hours also finds tasks that just became `VENCIDO`/`PROXIMO` as a side effect and prompts the user to confirm which were actually completed (`abrirConfirm`/`aplicarConfirm`) before writing `mant_historial` rows.

Each save also inserts one `mant_lecturas_horas` row per equipment (including the cascaded gearbox) with `horas_mes` (hours added this month) and `hrs_total` (cumulative). Readings are keyed by the equipment **name** (`equipo` text), not by `equipo_id`. They're only read by the history part of the Horas tab (`renderHoras()`).

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

### Certificados tab

`mant_certificados` tracks both the vessel's certificates and the crew's personal documents, with their expiry (section `============ CERTIFICADOS ============`):

- **Ship vs crew:** a row with `tripulante_id` (→ `mant_tripulantes`) is a personal document and must have `categoria = 'Tripulación'` (`CATEGORIA_TRIP`); without it, it's a ship certificate. The table check `mant_certificados_tripulante_check` enforces that both go together. A personal document's `departamento` always comes from its crew member: the trigger `mant_certificados_depto_tripulante` overwrites it on insert/update, and `mant_tripulantes_propagar_depto` copies a crew member's department change to all their documents.
- **Status:** `estadoCert(c)` → `VENCIDO` if `fecha_vencimiento` is before today (the expiry day itself is still valid), `PROXIMO` if within `dias_aviso` days (default 30, `DIAS_AVISO_CERT`), else `OK`. Derived, never stored.
- **Categories:** `categoria` is check-constrained (`mant_certificados_categoria_check`) and mirrored in the JS constant `CATEGORIAS_CERT` — **adding one means updating both**. `departamento` is `'Cubierta'` or `'Máquinas'`.
- **Renewal:** always through the RPC `mant_certificados_renovar(p_id, p_fecha_renovacion, p_vencimiento_nuevo, p_notas)` (`sb.rpc`), which inserts the `mant_certificados_historial` row and updates `fecha_vencimiento` in one transaction, taking `vencimiento_anterior` from the stored row and rejecting a new expiry that isn't later or a renewal date in the future. The future-date check in the function uses `current_date`, which is UTC and so never rejects the local "today"; the exact local check is done in `guardarRenovacionCert()`. It's `security invoker`, so RLS applies. Editing `fecha_vencimiento` directly in the edit modal is for corrections and leaves no history.
- **UI:**
  - Two sub-tabs, "🚢 Barco" and "👥 Tripulación". The active one is `certSolapa` (remembered in `localStorage`, key `cert-solapa`) and is switched with `cambiarSolapaCert()`.
  - Barco: list sorted by expiry, with filters for department and category.
  - Tripulación: one group per active crew member (`gruposTripulacion()`). Groups with something overdue come first, then upcoming, then the rest alphabetically. Filters are department and crew member, and the search box also matches the crew member's name and cargo.
  - `filtrosCert()`/`certFiltrados()` are shared by the list and the Excel export.
  - Adding a personal document uses the same modal (`abrirModalCert(null, tripulanteId)`). It hides category/department and suggests names from `DOCUMENTOS_TRIP`.
  - Tab and sub-tab badges count vencidos + por vencer.
  - The certificate edit modal lists the renewal history. Both the certificate and crew modals have "Dar de baja" (`activo = false`, no hard delete).
  - Inactive crew members only show up when the "Mostrar dados de baja" checkbox (`#cert-mostrar-bajas`) is ticked. They're listed last, greyed out, with no documents, and they're never exported. Their crew modal shows "Reactivar" (`reactivarTrip()`) instead of "Dar de baja". Their documents are kept in `certificadosBaja` only to count them, and come back with their history once the crew member is reactivated.
  - The Dashboard banner opens the sub-tab with the most urgent item (`irACertificados()`).
  - `exportarCertExcel()` exports exactly what's on screen, as two sheets (Certificados or Tripulación, plus Renovaciones). The file name carries the sub-tab and the filters.
  - History is loaded with `select('*, certificado:mant_certificados(nombre)')` so names survive soft-deletes.

### Postponement (postergación)

Overdue or upcoming tasks and certificates that were already reported to the company can be taken out of the alerts without changing their dates (section `============ POSTERGACIONES ============`).

- **Storage:** `mant_tareas` and `mant_certificados` have `postergada_hasta` (date) and `motivo_postergacion` (text). A table `check` makes them both null or both set.
- **Rule:** `estaPostergada(x)` is true while `postergada_hasta >= hoyLocalISO()`. The review day still counts as postponed, and the item comes back to the alerts by itself the day after. It's derived, never stored.
  - The status doesn't change: cards stay red or amber, with a "⏸ Postergada hasta …" label and the reason (`htmlPostergacion()`).
- **Excluded while postponed:**
  - The Dashboard counters, all banners (including the critical-task banner) and "Más urgentes".
  - The Tareas / Certificados / sub-tab badges, and `irACertificados()`.
  - Instead, `renderPostergadasDashboard()` shows a collapsible "⏸ N postergadas" line.
  - Equipment cards and fichas intentionally still count them.
  - The Tareas status filter has a "⏸ Postergadas" option.
- **UI:** "⏸ Postergar / Editar postergación" sits in the Registrar modal (tasks) and the certificate Editar modal. It only appears when the item is VENCIDO/PROXIMO or already has a postponement, and it opens `#modal-post`. Reason and review date are required, and the date must be after today. `quitarPost()` clears it.
- **Cleared on completion, with a trace:**
  - Registering a task clears both fields in all three places that register: `guardarMant()`, `aplicarChequeos()` and `aplicarConfirm()`. The `mant_historial` note gets "Estuvo postergada hasta DD/MM/AAAA: motivo" through `notasConTraza()`.
  - Renewing a certificate does the same inside `mant_certificados_renovar` ("Estuvo postergado hasta …").
- **Excel:** both exports include "Postergada hasta" and "Motivo postergación", filled only while the postponement is active.

### Dates

Older code computes "today" with `new Date().toISOString().split('T')[0]`, which is UTC and rolls over to tomorrow after 21:00 in Uruguay (UTC-3). New code uses `hoyLocalISO()` and `sumarDias()` (defined in the Deficiencias section); prefer those for new date logic.

### Auth

Supabase email/password auth (`sb.auth`). `chequearSesion()` runs on load; `onAuthStateChange` hides the app back to the login overlay on `SIGNED_OUT`. There is no signup flow in the UI — accounts are provisioned directly in Supabase.

## Database schema

`docs/esquema.sql` documents all thirteen `mant_*` tables plus their indexes, functions/triggers and RLS policies, matching the live project as of 2026-10-19 (it uses a placeholder owner email). **Keep it in sync**: whenever you apply a migration, update the file too. The live Supabase project is the source of truth if they ever disagree. Tables added beyond the original six:

- `mant_buque` — single row of vessel particulars.
- `mant_equipos` — equipment fichas; includes `activo` (soft delete) and `critico boolean not null default false`.
- `mant_lecturas_horas` — `equipo` (text name), `fecha`, `horas_mes`, `hrs_total`.
- `mant_deficiencias` — `anio`, `numero` (unique together, set by trigger `mant_deficiencias_numerar`), `equipo_id` → `mant_equipos(id)`, `descripcion`, `fecha_detectada`, `detectada_por`, `critica`, `fecha_limite`, `estado` (`'abierta'|'cerrada'`), `fecha_cierre`, `accion_realizada`, `creado_en`.
- `mant_tripulantes` — `nombre`, `cargo`, `departamento` (`'Cubierta'|'Máquinas'`, inherited by their documents), `activo`.
- `mant_certificados` — `nombre`, `categoria`, `tripulante_id` → `mant_tripulantes(id)` (nullable; set ⇔ `categoria = 'Tripulación'`), `departamento`, `fecha_vencimiento` (not null), `dias_aviso` (default 30), `observaciones`, `activo`.
- `mant_certificados_historial` — `certificado_id` → `mant_certificados(id)`, `fecha_renovacion`, `vencimiento_anterior`, `vencimiento_nuevo`, `notas`; written only by `mant_certificados_renovar()`.
- `mant_tareas` and `mant_certificados` both have `postergada_hasta` + `motivo_postergacion` (both null or both set).
- `mant_tareas` extra columns: `equipo_id` → `mant_equipos(id)`, `tipo_trabajo` (check-constrained code, nullable). `unidad` also allows `'ninguna'`.

Every `mant_*` table has RLS enabled with a single `<tabla>_owner` policy: `for all to authenticated using/with check ((auth.jwt() ->> 'email') = '<owner email>')`. New `mant_*` tables must copy that policy. Apply schema changes as migrations (`apply_migration`), then run the security advisors. Known pre-existing advisor warnings: `mant_update_timestamp` and `mant_update_timestamp_masc` have a mutable `search_path`, and Auth's leaked password protection is disabled.

## Conventions

- UI text, comments, and variable/function names are in Spanish (matching the vessel's crew); keep new code consistent with that.
- No dependency manager — new third-party libs are added as CDN `<script>` tags in `<head>`.
- XSS: any user-supplied string interpolated into `innerHTML` must go through `escape()`.
