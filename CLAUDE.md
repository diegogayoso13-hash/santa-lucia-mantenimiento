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

- `cargarTodo()` fetches all tables from Supabase in parallel on login/startup and populates global arrays (`tareas`, `tareasTodas`, `historial`, `repuestos`, `herramientas`, `tareaRepuestos`, `buque`, `equipos`, `lecturas`, `deficiencias`, `certificados`, `certHistorial`, `tripulantes`).
  - **Paging:** PostgREST returns at most 1000 rows per request, so every list goes through `traerTodo(() => consulta)`, which pages with `.range()` until it has everything. The callback must build a fresh query each time with a stable order (add `.order('id')` as a tie-breaker). New list loads must use it too.
  - **Active rows:** `mant_tareas` is loaded in full into `tareasTodas`; `tareas` holds only the active ones (`activa = true`) and is what everything else uses (status, Dashboard, alerts, filters, hours). `mant_equipos` and `mant_certificados` load only `activo = true` — tasks with history, equipment, certificates and crew are soft-deleted, never hard-deleted. `tripulantes` is loaded in full (including inactive), and `certificados` drops the documents of inactive crew members right after loading.
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

`calcularEstado(t)` is the core rule. `mant_tareas.unidad` says how a task is controlled:

| `unidad` | Interval column | Compares |
|---|---|---|
| `'hrs'` | `cada_hrs` | `proxima_hrs` vs `hrs_totales` |
| `'fecha'` | `cada_meses` | `proxima_fecha` vs today |
| `'ambos'` ("lo que ocurra primero") | both | both |
| `'ninguna'` | — | nothing (always `SIN_DATO`) |

- **Thresholds:** `VENCIDO` (overdue) if the difference is ≤ 0, `PROXIMO` (upcoming) if it's within the task's threshold, otherwise `OK`; `SIN_DATO` if there's no data.
  - The threshold is proportional to the task's interval: `umbralProximoHrs(t)` = max(10% of `cadaHrs`, 30 hrs) and `umbralProximoDias(t)` = max(10% of `cadaMeses` × 30 days, 7 days). Tasks without an interval fall back to 100 hrs / 30 days.
  - The percentage, minimums and fallbacks are the `PROXIMO_*` constants at the top of the script (section `SEMÁFORO DE TAREAS`).
  - Every place that colours tasks goes through these: `estadoPorHoras()`/`estadoPorFecha()` (so `calcularEstado()`), "Registrar varias" (`renderChequeosFecha()` calls `estadoPorFecha()`), and the hours-entry prompt in `guardarCarga()`. Deficiencies, spare parts and certificates have their own rules and don't use them.
- **`'ambos'`:** the worse side wins (VENCIDO > PROXIMO > OK). The other side comes back in `.otro`, and the card shows both.
- **Where it's used:** everywhere status is displayed (dashboard counts, task list, equipment cards). Status is always derived, never stored.
- **Helpers:**
  - `usaHoras(t)` / `usaFecha(t)` tell which sides apply. Use them instead of comparing `unidad` to `'hrs'`/`'fecha'` directly.
  - `cadaHrs(t)` / `cadaMeses(t)` return the intervals, falling back to parsing `periodicidad` for rows without the columns.
  - `sumarMeses()` adds months to a date.
- **`periodicidad`** is display text only. `etiquetaPeriodicidad(t)` builds the label from the interval columns, and `textoPeriodicidad()` writes it on create/edit.
- **The table check** `mant_tareas_control_check` requires the interval(s) for each `unidad`.
- **Registering:**
  - `guardarMant()` never changes `unidad`. It updates `proxima_hrs` and/or `proxima_fecha` according to `usaHoras`/`usaFecha`, and `'ambos'` requires the hours.
  - The monthly hours confirmation (`aplicarConfirm()`) also recalculates `proxima_fecha` for `'ambos'`.
  - "Registrar varias" lists only `'fecha'` tasks: `'ambos'` are left out on purpose, so their hours are checked in the Registrar modal.
- **Editing:** "✏️ Editar tarea" in the Registrar modal (`abrirEditarTarea()`) reuses `#modal-tarea` in edit mode.
  - It changes the name, priority, work type and control. The equipment is fixed, because hour cascading and filters match on its name.
  - Next hours/date are recalculated only when the control or an interval changes (`controlCambia()`), counting from `ult_hrs` / `fecha_ult`. If those are missing, it asks for "contar desde".
  - The side that stops being used is cleared.

### Retiring tasks and fixing history

- **Dar de baja:** the left button of the Registrar modal (`#m-btn-baja`, `bajaOBorrarTarea()`) depends on the task:
  - With history it reads "⏹ Dar de baja" and sets `activa = false`. A task with history is never deleted, because `mant_historial` (and `mant_tarea_repuestos`) cascade on delete.
  - Without history it reads "🗑 Borrar tarea" and hard-deletes. The confirmation says how many linked spare parts get unlinked.
- **Retired tasks:**
  - They're out of `tareas`, so they don't show in the Dashboard, alerts, badges, hours entry or Registrar varias.
  - The "Mostrar dadas de baja" checkbox in Tareas (`#filtro-bajas`) lists them last, greyed (`renderTaskCardBaja()`), filtered by the same non-status filters, with "↺ Reactivar" (`reactivarTarea()`).
  - Their history still shows everywhere (Historial tab, equipment ficha and charts, Excel), marked "(dada de baja)" through `htmlTareaHist()`. History lists must resolve tasks through `tareasTodas`, not `tareas`.
  - Hour loads update `hrs_totales` by equipment name for all rows, so a reactivated task has current hours.
- **Historial tab list and Excel:** `historialFiltrado()` applies the equipment filter and the search box (`filtrosHist()`), sorts newest first and includes retired tasks. Both `renderHistorial()` and the tab's "📥 Exportar Excel" (`exportarHistExcel()`) use it, so the file is exactly what's on screen.
  - The file has one "Historial" sheet with Fecha, Equipo, Tarea (with "(dada de baja)"), Hrs equipo, Realizado por and Notas.
  - It's named `Historial_<equipo or Todos>[_busqueda-<text>]_<date>.xlsx`. With no rows it doesn't download and shows a toast instead.
- **Fixing a history record:** every record in the Historial tab and the equipment ficha has a ✏️ button that opens `#modal-hist` (`abrirModalHist()`) to edit date (not after today), hours, who and notes, or delete it.
  - The task stores its last completion and next due itself; they aren't derived from history. `recalculoTarea()` compares what `datosDesdeHistorial()` gives before and after the change. The task is updated only if that differs, i.e. when the change affects the latest record.
  - **Recalculation:** same rule as `guardarMant()`. `fecha_ult`/`proxima_fecha` come from the most recent record; `ult_hrs`/`proxima_hrs` come from the most recent record that has hours. `hrs_totales`, `unidad`, observations and postponement are never touched.
  - The modal previews the result ("La tarea queda: …") and has a "Recalcular la tarea" checkbox, ticked by default.
  - If no records (or no records with hours) are left, that side of the task is left as is and the user is warned to fix it with "✏️ Editar tarea".

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
- `mant_tareas` extra columns: `equipo_id` → `mant_equipos(id)`, `tipo_trabajo` (check-constrained code, nullable), `cada_hrs` / `cada_meses` (control intervals). `unidad` also allows `'ambos'` and `'ninguna'`.

Every `mant_*` table has RLS enabled with a single `<tabla>_owner` policy: `for all to authenticated using/with check ((auth.jwt() ->> 'email') = '<owner email>')`. New `mant_*` tables must copy that policy. Apply schema changes as migrations (`apply_migration`), then run the security advisors. Known pre-existing advisor warnings: `mant_update_timestamp` and `mant_update_timestamp_masc` have a mutable `search_path`, and Auth's leaked password protection is disabled.

## Test version (`prueba/`)

`prueba/index.html` is a separate copy of the app, published at `/prueba/`, for trying out changes without touching the real one. Changes to the root `index.html` are **not** copied to it (or back) automatically.

- **Backend:** it points to a different Supabase project, "Mantenimiento Naval" (`ncughlkgdgigwkggnxri`), which holds a copy of the data. The real app and its project (`zfoetyauhauztkkltjaz`) must never be touched when working on the test version.
- **Separation:** it shows a fixed orange banner ("VERSIÓN DE PRUEBA – no cargar datos reales") and a `[PRUEBA]` tab title, and its `localStorage` keys carry a `prueba-` prefix (`prueba-nav`, `prueba-cert-solapa`, `prueba-barco`).
- **Several ships:** the test database holds several ships. Its schema is documented in `docs/esquema_prueba.sql`, and `docs/esquema.sql` still describes the real project.
  - **Ships table:** `mant_buque` is the ships table, one row per ship (id 1 = B/M Santa Lucía).
  - **`barco_id`:** every other `mant_*` table has `barco_id not null` → `mant_buque(id)`.
  - **Mixing ships is blocked:** child tables reference their parent by `(barco_id, id)` composite foreign keys, so the database rejects rows that mix ships.
  - **Deficiency numbering** is per ship and per year.
  - **No default:** `barco_id` has no default, so a row the app forgets to tag fails instead of landing on the wrong ship.
  - **Gearboxes:** "Toma las horas de" (`mant_equipos.horas_de_id`) replaces the old hard-coded `CAJAS_POR_MP`. A piece of equipment can take its hours from another one on the same ship (enforced by a composite FK), and a trigger rejects loops and self-references.
- **Companies, users and roles:** the test database no longer uses the "only my email" policy.
  - **Companies:** every ship belongs to a company (`mant_buque.empresa_id` → `mant_empresas`), and data never crosses companies.
  - **Access:** `mant_accesos` gives a user (`auth.users`) a role. `admin_empresa` is per company (no ship) and covers all its ships; `jefe`, `operador` and `lectura` are per ship.
  - **What each role can do:**
    - `jefe` can do everything in their ships.
    - `operador` can see everything and add records: history, hour readings, deficiencies and stock movements. It can also edit and close open deficiencies.
    - A trigger limits `operador` updates to a task's status columns (registering, hours) and to a spare part's `cantidad`.
    - `lectura` can only see.
    - The admin can create ships and manage access in their company, except their own access row.
  - **RLS:** every table's policies call `SECURITY DEFINER` helpers in the `mant_priv` schema, which the API doesn't expose. `mant_priv.barcos(nivel)` returns the user's ships at that level or higher, with levels 1 lectura, 2 operador, 3 jefe. Policies wrap the helpers as `(select …)::integer[]` so they run once per query.
  - **Authorship:** `creado_por` (history, hour readings, movements, deficiencies) and `cerrada_por` (deficiencies) are set by triggers from `auth.uid()`, so the app can't fake them. Rows written straight from SQL or the dashboard (no app session) keep whatever is sent.
  - **New users:** sign-ups are meant to be off. Users are created in the dashboard (Authentication → Users), then given a `mant_accesos` row.
  - The full rules are in `docs/esquema_prueba.sql`.
- **The test app works per ship** (section `BARCOS Y ROLES` in `prueba/index.html`):
  - **Startup:** after login, `iniciarApp()` → `cargarBarcos()` reads the user's own `mant_accesos` rows and the ships they can see. It builds `barcosDisponibles` (each with the user's highest role there) and picks `barcoActual`, the last one used (`prueba-barco`) or the first. A user with no ships sees `#sin-barcos` and nothing else.
  - **Header:** the ship name comes from its ficha. With more than one ship it becomes a `<select id="sel-barco">`. Next to it is the role badge (`#header-rol`), and the tab title follows the ship. `cambiarBarco()` closes open modals and the equipment ficha, then reloads everything.
  - **Reads and writes:**
    - Every read in `cargarTodo()` filters `.eq('barco_id', B)` (`mant_buque` by `id`) and ignores a late answer for a ship that's no longer selected.
    - Every insert wraps its data in `conBarco()`.
    - The hour updates by equipment name also filter by `barco_id`.
  - **Hour cascading:** `equiposQueTomanHorasDe(nombre)` gives the equipment that receives a piece of equipment's hours (also down a chain), and `equiposOcultosCarga()` hides those from the hours form. The "Toma las horas de" select (`llenarSelectorHorasDe()`) leaves out the equipment itself and anything that already takes its hours.
  - **Excel files:**
    - **Names** carry the ship (`nombreBarcoArchivo()`) and go through `textoArchivo()`, so they have no accents, ñ, signs or spaces (`Stock_BM_Santa_Lucia_2026-10-29.xlsx`). `busquedaArchivo()` adds the search text.
    - **Plan export:** the Tareas tab's "📥 Exportar Excel" opens `#modal-export-plan` (`abrirExportarPlan()` / `exportarPlan()`). It offers all equipment or a choice grouped by ficha category, plan and/or history, all tasks or only overdue and upcoming ones (postponed included), and full history or a date range.
      - The last choice is kept in `prueba-exportar-plan`.
      - The name reflects the choice, e.g. `BM_Santa_Lucia_3_equipos_Plan_vencidas_2026-10-29.xlsx`.
    - **Other exports:** Stock, Herramientas and Deficiencias export exactly what's on screen (`stockFiltrado()`, `herrFiltradas()`, `defFiltradas()` are shared with the lists), and the name carries the filters.
    - **Filter selects:** they're rebuilt on every render through `llenarSelectConservando()` so the choice survives (before, the stock category and the tool location and brand filters reset themselves and never filtered).
  - **Buttons by role:** `body` gets `puede-registrar` (operador and up) and `puede-editar` (jefe and up) in `renderEncabezado()`. Elements marked `.solo-operador` (register, hours form, deficiencies, stock movements) or `.solo-jefe` (everything that changes the plan, fichas, history fixes, postponing, renewing) are hidden by CSS otherwise. New action buttons need one of these classes. The database still enforces everything.
  - **Errors:** `textoError(err)` turns permission rejections (code `42501`, RLS messages) into "No tenés permiso para esto". Use it in every error toast.
- **Administration (section `ADMINISTRACIÓN`, only `admin_empresa`):** a fifth top section "⚙️ Admin" (`.solo-admin`, body class `puede-administrar`) with sub-tabs `admin-barcos` and `admin-usuarios`. It works on the company of the selected ship. `cambiarTab()` sends non-admins back to the dashboard.
  - **Adding a ship:** it reuses `#modal-buque` (`buqueNuevo = true`, `abrirNuevoBarco()`) plus "Copiar desde otro barco". `crearBarco()` calls the RPC `mant_barco_crear(p_empresa, p_ficha, p_origen, p_copiar)`, which creates everything or nothing.
    - **Copied:** active equipment, with no serial number, years, state or notes; "Toma las horas de" is remapped to the new equipment.
    - **Copied with values reset:** active tasks without last date or hours (so "sin registrar"); spare parts with stock 0; tools with quantity 0; ship certificates without an expiry date.
    - **Never copied:** history, readings, deficiencies, movements, crew or stock.
  - **Certificates without a date:** `fecha_vencimiento` can be null. `estadoCert()` gives `SIN_FECHA`, shown as "📅 Falta cargar el vencimiento". It counts in the tab badge, has no "Renovar" button, and `mant_certificados_renovar` rejects it.
  - **Users:** the list comes from `mant_accesos` plus `mant_perfiles` (`cargarUsuariosEmpresa()`).
    - Role and ships are saved at once with the RPC `mant_accesos_guardar`. "Quitar acceso" deletes the user's rows for the company.
    - Sign-ups, temporary passwords and "change my password" go through the Edge Function `mant-usuarios` (`llamarUsuarios()`, source in `supabase/functions/mant-usuarios/index.ts`). It checks the caller with their session and writes `mant_accesos` through `mant_accesos_guardar` with the caller's session, so RLS applies.
    - **Temporary password:** shown once (`#modal-clave-temp`). A temporary password for someone else is only allowed for users who belong solely to the admin's companies.
    - **First login:** `mant_perfiles.debe_cambiar_clave` forces the change (`chequearClaveObligatoria()`, `#modal-clave`, which can't be dismissed, only "Salir").
    - **🔑 in the header:** "Cambiar mi contraseña" for everyone; it asks for the current password.
    - The admin's own row has no actions.
  - **Service role:** the project's `service_role` had no table grants. It only gets `select` on `mant_accesos` and `select, insert, update` on `mant_perfiles`.

## Conventions

- UI text, comments, and variable/function names are in Spanish (matching the vessel's crew); keep new code consistent with that.
- No dependency manager — new third-party libs are added as CDN `<script>` tags in `<head>`.
- XSS: any user-supplied string interpolated into `innerHTML` must go through `escape()`.
