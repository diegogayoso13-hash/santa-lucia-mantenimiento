# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-page web app for managing shipboard maintenance on the B/M Santa Lucía (a tugboat), replacing a monthly Excel-sheet workflow. No framework, no build step: the entire app (markup, CSS, JS) lives in `index.html`. Backend is Supabase (Postgres + Auth), loaded via CDN `<script>` tags (`@supabase/supabase-js@2`, `xlsx@0.18.5` for Excel export, `chart.js@4.4.1` for the equipment charts).

The Supabase project is "Mantenimiento Naval" (`ncughlkgdgigwkggnxri`), which supports several ships, companies and roles (see "Several ships, companies and roles" below). The app moved there on 2026-11-01 (`docs/mudanza.md`, git tag `antes-mudanza`). The old project (`zfoetyauhauztkkltjaz`) is shared with another app in use and kept as a backup: **never write to it, change it or touch its permissions**. There is no separate test version any more.

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
  - **Active rows:** tasks with history, equipment, certificates and crew are soft-deleted, never hard-deleted.
    - `mant_tareas` is loaded in full into `tareasTodas`. `tareas` holds only the active ones (`activa = true`) that aren't paused (see "Retired equipment"), and is what everything else uses (status, Dashboard, alerts, filters, hours).
    - `mant_equipos` is loaded in full into `equiposTodos`. `equipos` holds only `activo = true`, and every list and selector uses it.
    - `mant_certificados` loads only `activo = true`.
    - `tripulantes` is loaded in full (including inactive), and `certificados` drops the documents of inactive crew members right after loading.
- `renderTodo()` re-renders every section from those in-memory arrays. There's no reactive framework: after any mutation (save/delete), code calls `cargarTodo()` again (or manually patches the array + calls the relevant `renderX()`), not a diffing re-render.
- Tab switching (`cambiarTab`) just toggles `.active` on `<section>` elements — all tabs are already in the DOM, nothing is lazy-loaded.

### Navigation (two levels)

The top bar has these sections, each with its sub-tabs underneath:

| Section | Sub-tabs |
|---|---|
| 📊 Inicio | Dashboard |
| 🔧 Mantenimiento | Tareas, Deficiencias, Horas, Historial |
| ⚓ Barco | Mi Barco, Equipos, Certificados |
| 📦 Pañol | Stock, Herramientas |
| ⛽ Consumos | Combustible, Sondas, Rellenos (for now only `admin_empresa`, see "Combustible", "Sondas" and "Rellenos de aceite"). Internal section key: `combustible` |
| ⚙️ Admin | Barcos, Usuarios (only `admin_empresa`) |

- **Restricted sections:** `puedeVerSeccion()` says who may open a section. `cambiarTab()` and `renderEncabezado()` send everyone else back to the dashboard, and the buttons are hidden with `.solo-admin` / `.solo-combustible`.

- **Markup:** each sub-tab is a `.tab` button with `data-tab` (opens `<section id="sec-<tab>">`) and `data-seccion`. `SECCION_DE_TAB` is built from those attributes, so **a new tab only needs its button and section**.
- **Navigating:** always call `cambiarTab('<sub-tab>')`. It activates the section too, shows only that section's sub-tabs, and hides the sub-tab row when the section has a single sub-tab.
  - Clicking a section (`cambiarSeccion()`) reopens the last sub-tab used in it.
  - The current tab and the last sub-tab per section are saved in `localStorage` (key `nav`) and restored on load.
- **Section badges** (`#badge-sec-*`) are the sum of the visible sub-tab badges, recomputed by a `MutationObserver` whenever any sub-tab badge changes. The code that sets the sub-tab badges never touches them.
- On mobile the sections share the width (icon above the label) and the sub-tab row scrolls horizontally.

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

Monthly hours are entered per top-level equipment. Equipment with "Toma las horas de" (`mant_equipos.horas_de_id`, e.g. each `Caja Reductora Babor/Estribor` takes its `Motor Principal`'s hours) silently receives the same hours when hours are saved for its source (`guardarCarga()`, `equiposQueTomanHorasDe()`), and is hidden from the manual entry form (`equiposOcultosCarga()`). Saving hours also finds tasks that just became `VENCIDO`/`PROXIMO` as a side effect and prompts the user to confirm which were actually completed (`abrirConfirm`/`aplicarConfirm`) before writing `mant_historial` rows.

**Hours-entry form (`renderCarga()`):** hours are entered as service hours for the month; there's deliberately no hour-meter field, because the hour meters aren't trusted.

- **Last reading:** each row shows the equipment's latest reading ("Última carga: dd/mm/aaaa · total h", from `ultimaLecturaEquipo()`), or "Sin cargas".
- **Impossible hours:** `avisoHorasPosibles()` shows a yellow warning when "Horas del mes" is more than the hours possible since that reading (days between its date and "Fecha de la carga" × 24), or when the entry date isn't later than the reading. Saving is still allowed.
  - Changing the entry date re-checks all rows (`revisarAvisosHoras()`).
  - With no readings there's nothing to compare against.

Each save also inserts one `mant_lecturas_horas` row per equipment (including the cascaded gearbox) with `horas_mes` (hours added this month) and `hrs_total` (cumulative). Readings are keyed by the equipment **name** (`equipo` text), not by `equipo_id`. They're only read by the history part of the Horas tab (`renderHoras()`).

### Ship & equipment fichas ("Mi Barco" / "Equipos" tabs)

`mant_buque` (one row per ship; the app shows the selected ship's) holds vessel particulars (dimensions, tonnage, registry, engines) rendered by `renderBarco()`. `mant_equipos` holds one row per piece of equipment (engine, generator, compressor, etc.) with free-text technical data, rendered as a grid (`renderEquipos()`) and a detail view (`renderFichaEquipo()`) with Chart.js graphs of hours-over-time and maintenance history (`renderGraficosEquipo()`). Tasks can optionally link to an equipment row via `tarea.equipo_id`, which makes the equipment name clickable to jump to its ficha. Note that tasks also carry the equipment name as free text (`tarea.equipo`), and the Tareas filters, hour cascading and `mant_lecturas_horas` match on that name, not on `equipo_id`.

### Retired equipment

- **Retiring:** "⏹ Dar de baja" in the equipment modal (`darDeBajaEquipo()`, jefe/admin) sets `mant_equipos.activo = false`. Nothing is deleted.
- **While retired**, the equipment's active tasks (`activa = true`, linked by `equipo_id`) are **paused** (`tareaEnPausa()`):
  - they're left out of `tareas`, so they count nowhere (Dashboard, alerts, Tareas list, badges, hours entry, Registrar varias);
  - they're not changed in the database, so they come back by themselves when the equipment is reactivated;
  - tasks linked only by the equipment's name (no `equipo_id`) are not paused.
- **Equipos tab:** "Mostrar dados de baja" (`#eq-mostrar-bajas`, remembered in `localStorage` key `eq-mostrar-bajas`) lists the retired equipment last, greyed, labelled "De baja".
- **Retired equipment's ficha:** it shows "De baja", "↺ Reactivar" (`reactivarEquipo()`, jefe/admin) instead of "Editar ficha", and its paused tasks greyed (they can't be registered while paused).

### Equipment ficha history

`renderHistorialFicha()` (section `============ HISTORIAL DEL EQUIPO (ficha) ============`) draws one timeline in `#ficha-historial-list`. It only displays data; nothing is changed.

- **What it mixes:**
  - completed tasks (`mant_historial`, with the ✏️ fix button);
  - the equipment's deficiencies (`mant_deficiencias` by `equipo_id`, placed by `fecha_detectada`);
  - oil top-ups and changes (`mant_rellenos`). These appear only when `puedeVerCombustible()`, like the rest of Consumos.
- **Order** (`itemsHistorialEquipo()`): open deficiencies first (critical, then by deadline; red when critical or overdue), then everything else newest first.
- **Filter:** Todo / Tareas / Deficiencias / Aceite (`filtroHistFicha`, reset when opening a ficha), with counts.
- **Deficiency detail:** tapping a deficiency opens the read-only `#modal-def-detalle` (`abrirDetalleDef()`), with "Cerrar" / "Editar" for open ones, using the Deficiencias tab modals.
  - "Quién la cerró" comes from `cerrada_por` through `nombreUsuarioComb()`; it's "—" when empty.
  - `renderTodo()` calls `renderHistorialFicha()`, so the open ficha refreshes after closing or editing.
- **Excel:**
  - "📥 Exportar historial" (`exportarHistorialEquipo()`) exports what the filter shows.
  - The Tareas tab's plan export adds a "Deficiencias" sheet when Historial is chosen. It uses the same equipment (matched by name) and date range (by `fecha_detectada`).

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

### Combustible (fuel)

Stages 1 and 2 of 3 (section `============ COMBUSTIBLE ============`). Fuel is tracked per ship by **period** (`mant_combustible_periodos`), each with its supplier loads (`mant_combustible_cargas`, deleted with the period), plus transfers (`mant_combustible_trasvases`).

- **Periods:**
  - `desde`/`hasta` default to the calendar month after the last period, or to "15 to 15" if the last one didn't end on a month's last day (`fechasNuevoPeriodoComb()`). Both are editable.
  - Periods of a ship can't overlap, but they may share the boundary day. The trigger `mant_priv.combustible_sin_solape` enforces this, and the app checks it first.
  - `fin_litros` null means the period is "en curso".
- **Inicio:** `inicio_litros` is prefilled from the previous period's `fin_litros` (`periodoAnteriorComb()`: latest `hasta` ≤ this `desde`) and stored. Without a previous period it's typed in. When it differs from the previous end, `avisoInicioComb()` shows a warning, both in the modal and in the list.
- **Periods list (`renderCombustible()`):** one row per period builds both a compact table and a phone card. CSS shows the table above 700 px and the cards (`.comb-tarjetas`) at 700 px or less.
  - **Columns:** Período | Inicio | Cargado | Recibido | Entregado | Fin | Consumo | l/h | H nav | MMPP | MGAs | Millas | icons. The table fits without horizontal scroll at 1366 px; a scroll is kept only as a fallback for widths between 700 and about 1.140 px.
  - **Período** is short (`textoPeriodoCortoComb()`: `01/10–31/10/26`, or with both years when it crosses a year); forms and Excel keep the long `textoPeriodoComb()`.
  - **Consumo** is bold.
  - **Edit/delete** are icon-only buttons (`.btn-ico`) with a `title`.
  - **Empty cells:** Cargado, Recibido, Entregado, H nav, MMPP, MGAs and Millas show "—" for both empty and 0 (`fmtSiHayComb()`), while Inicio/Fin/Consumo show a real 0.
- **Calculated, never stored:**
  - consumo = inicio + cargado + recibido − entregado − fin (`consumoComb()`); `datosPeriodoComb()` adds the period's transfers.
  - l/h = consumo / `horas_navegacion` (`promedioComb()`), shown as "—" with 0 or no hours.
  - A negative consumption shows a warning.
- **Trasvases (stage 2):**
  - A transfer is entered once, with `origen_barco_id` (gives) and `destino_barco_id` (receives).
  - Between two ships of the system, both sides are set, and it shows and counts on both ships. They must be different ships of the same company (check + trigger `mant_priv.combustible_trasvase_misma_empresa`).
  - With a ship outside the system (e.g. RIA, SFR), the other side is null and `otro_buque` holds its name. It counts only on the system ship.
  - **Which period counts it:** it isn't tied to a period. Each ship counts it in its own period by date. On a shared boundary day it goes to the period that **starts** that day: `periodoDeFechaEn()` in the app, `mant_priv.periodo_combustible` in the database, same rule. A transfer that falls in no period shows "⚠️ Sin período" and counts nowhere.
  - **In the app:** the period modal no longer has a transfer field. It shows the transfers of its dates (`trasvasesDeRangoComb()`), and they're entered with "➕ Trasvase" (`#modal-trasv`, `abrirModalTrasv()` / `guardarTrasv()` / `borrarTrasv()`). The list is `renderTrasvasesComb()`.
  - **Names of the other ship** come from the RPC `mant_combustible_barcos()`: id and name of the company's ships, even ones the user can't access. It's `security invoker` and calls `mant_priv.barcos_empresa()`. They're loaded into `combBarcos` and resolved with `otroBuqueTrasv()`.
  - **Permissions:** `mant_priv.trasvase_permitido(origen, destino, fecha)` is used for insert, update (old and new row) and delete. The user must be operador+ on at least one side, and for each system side the period of that date must be en curso or not exist yet, or the user must be jefe/admin there. Nobody changes a closed period of a ship where they aren't jefe.
  - The app only knows its own side (`puedeEditarTrasvUI()`); it uses `.select()` on update/delete to detect a silent RLS refusal and show "No tenés permiso".
- **Permissions (enforced by RLS too):**
  - lectura sees.
  - operador adds and edits only periods en curso, and their loads. It can type the end, which closes the period for it, and can't insert an already-closed period: the modal disables "fin" on a new period for non-jefes.
  - jefe and admin edit any period. Deleting is jefe and admin only.
  - `guardarComb()` saves the loads before the period update, so an operador closing a period can still save its loads.
- **Visibility:** for now the tab is only for `admin_empresa`. `puedeVerCombustible()` is the single switch (body class `puede-combustible`, elements `.solo-combustible`); the database rules are already per role.
- **Authorship:** `creado_por` comes from `mant_priv.registrar_autor`, and `actualizado_por`/`actualizado_en` from `mant_priv.combustible_actualizado`. The modal shows them through `nombreUsuarioComb()`, which only knows emails of the admin's company users.
- **Excel:** `exportarCombExcel()` writes two sheets to `Combustible_<barco>_<fecha>.xlsx`:
  - "Combustible": Período, Inicio, Consumo, Trasvase a otro buque (= entregado), Recibido de otro buque, Cargado, Fin, MMPP, MGAs, Millas, Hr navegación, Consumo promedio (l/h).
  - "Trasvases": Fecha, Tipo, Otro buque, Fuera del sistema, Litros, Período, Notas.
- **Dashboard card "⛽ Combustible a bordo"** (`#dash-combustible`, `renderCombustibleInicio()`): it's drawn by its own function, called from `renderTodo()`, and `renderDashboard()` doesn't touch it. It follows the tab's visibility (`.solo-combustible`).
  - **Shows** the last sounding: `fin_litros` of the most recent period that has one (`ultimaSondaComb()`), with its `hasta` date and "hace X días".
    - With `mant_buque.capacidad_combustible_litros`, it adds a bar with the % (rounded).
    - It adds a "Desde esa sonda: +cargados · +recibidos · −trasvasados" line (`movimientosDesdeSondaComb()`: loads and transfers that count in later periods, or transfers dated after the sounding that fall in no period). There is never an estimate.
  - **Turns yellow** when the sounding is older than `DIAS_SONDA_VIEJA` (45) days.
  - **Hidden** when there's no period with an end.
  - Clicking it opens ⛽ Combustible.
  - The capacity field is hidden when adding a ship, because `mant_barco_crear` doesn't copy that column; it's set later by editing the ficha.

### Sondas (tank soundings)

Stage 1 (section `============ SONDAS ============`, sub-tab `sondas` of ⛽ Consumos, same visibility switch as Combustible). It replaces the paper soundings notebook.

- **Tanks (`mant_tanques`):**
  - Each tank has `codigo`, `servicio`, `contenido`, `capacidad_litros` and `orden` (the column order).
  - `servicio` is check-constrained (`mant_tanques_servicio_check`) and mirrored in `SERVICIOS_TANQUE`, with colors in `COLOR_SERVICIO`. **Adding one means updating both.**
  - The code is unique per ship. Tanks are retired with `activo = false`, never deleted, so their readings are kept.
  - Managed in `#modal-tanques` / `#modal-tanque` (`abrirModalTanques()`, `guardarTanque()`, `cambiarActivoTanque()`); jefe/admin only.
- **Soundings:**
  - A sounding (`mant_sondas`) is one date per ship (`unique (barco_id, fecha)`) plus observations.
  - Its readings (`mant_sondas_lecturas`) hold the litres per tank, deleted with the sounding. **No row = not measured**, which is different from 0.
  - The form (`#modal-sonda`, `abrirModalSonda()` / `guardarSonda()` / `guardarLecturasSonda()`) has one row per active tank, plus retired tanks that have a reading in that sounding.
    - "Vacío" sets 0 and "Lleno" sets the capacity.
    - Negative values block saving. Above capacity only warns (`sondaAvisoFila()`); the database accepts it.
- **Permissions:**
  - `mant_priv.sonda_permitida(barco, id, fecha)`: jefe/admin always; operador only if no other sounding of the ship has the same or a later date. So an operador adds new soundings and edits only the latest; the lecturas policies use the same rule through their sounding.
  - Deleting soundings and managing tanks: jefe/admin.
  - The app mirrors this with `puedeEditarSonda()` / `esUltimaSonda()` and detects silent RLS refusals with `.select()`.
- **Screen (`renderSondas()`):**
  - It's laid out like the notebook: one row per date, newest first, and one column per tank in `orden` (`tanquesColumnas()`: active tanks, plus retired ones that have readings, shown greyed).
  - A header row groups consecutive tanks of the same service by color.
  - After the last fuel tank comes "Total comb." (`celdasSondas()`, `totalCombustibleSonda()`: sum of the measured fuel tanks), shown when there are two or more fuel tanks.
  - At 700 px or less it shows one card per sounding.
  - The Excel (`exportarSondasExcel()`) uses the same layout: a services row (merged cells), a tank-codes row, the total and the observations.
- **Link with Combustible:** next to "Fin" in the period form, `combNotaSonda()` offers the sounding closest to the period's `hasta` (`sondaCercana()`, within `DIAS_SONDA_CERCANA` = 5 days either way; on a tie, the later one). It shows "Sonda del dd/mm: X L (TK 5 + TK 6)" with a "Usar" button and notes unmeasured fuel tanks. It never fills the field by itself.
- **Dashboard card "📏 Tanques"** (`#dash-tanques`, `renderTanquesInicio()`): the latest sounding with its date and "hace X días".
  - Non-ballast active tanks get one bar each with their %.
  - Ballast tanks are listed in small text as Vacío / Lleno / litres / sin medir.
  - Clicking it opens Sondas.

### Rellenos de aceite (oil top-ups)

Section `============ RELLENOS ============`, sub-tab `rellenos` of ⛽ Consumos, same visibility switch as Combustible. It started on 2026-11-03 with no history. Not built yet: importing history, and an automatic oil change when a task is completed.

- **Oils (`mant_aceites`):**
  - Each oil has `nombre` (unique per ship), `tipo`, and `tanque_id` (where it's stored: a tank of `mant_tanques`; null = "tambor/bidón").
  - `tipo` is check-constrained (`mant_aceites_tipo_check`) and mirrored in `TIPOS_ACEITE`. **Adding one means updating both.**
  - Oils are retired with `activo = false`, never deleted.
  - Managed in `#modal-aceites` / `#modal-aceite`; jefe/admin only.
- **Oil per equipment:** `mant_equipos.aceite_id` (nullable, same-ship composite FK) is set with the "Aceite" select in the equipment modal (`llenarSelectorAceite()`). The ficha shows it as a pill.
  - It's separate from the older free-text `aceite_tipo`. For the gearboxes both now say "Mobil Delvac 15W40".
- **Top-ups (`mant_rellenos`):** each one has `fecha`, `equipo_id`, `aceite_id` (proposed from the equipment, changeable), `litros` (> 0), `tipo` (`'Relleno'|'Cambio'`) and `observaciones`. Authorship comes from triggers.
  - They're loaded with an embed (`equipo:mant_equipos(nombre)`) so names survive equipment soft-deletes; display them with `nombreEquipoRelleno()`.
- **Permissions:**
  - Everyone sees; operador+ adds.
  - jefe/admin edit anything. operador edits only its own top-ups on the day it entered them, in Uruguay time (`mant_priv.relleno_propio_del_dia`); `creado_en` can't be changed (trigger `mant_priv.conservar_creado_en`). The app mirrors this with `puedeEditarRelleno()`.
  - Deleting is jefe/admin.
- **Screen (`renderRellenos()`):**
  - Filters by equipment, oil and date range (`filtrosRellenos()` / `rellenosFiltrados()`, shared with the Excel), with the total litres of what's filtered.
  - A table on PC (newest first) and cards at 700 px or less.
  - `exportarRellenosExcel()` exports what's on screen; the file name carries the filters.
- **Equipment ficha:** `renderRellenosFicha()` fills `#ficha-rellenos` with:
  - the "🛢️ Relleno" button (`abrirModalRelleno(null, equipoId)`);
  - the totals of the last 30 and 90 days, counting today;
  - the last 5 top-ups.
- **Oil consumption by sounding:** it sits at the top of the same sub-tab (`renderConsumoAceite()`, called from `renderRellenos()`).
  - **Tank use:** each oil tank has `mant_tanques.uso_aceite`: `'Reserva'` (equipment is topped up from it) or `'Sistema'` (a system's reservoir, whose level should hold).
    - A check allows it only on oil tanks. It's set with the "Uso" select in the tank modal (`tanqueServicioCambiado()`, `SERVICIOS_ACEITE`), and `guardarTanque()` clears it for other services.
  - **Tank loads (`mant_cargas_aceite`):** each one has `fecha`, `tanque_id` (oil tanks only, checked by trigger `mant_priv.carga_aceite_tanque_valido`), `litros` and `origen` (`'Proveedor'|'Tambor/bidón'`); the supplier's name goes in `observaciones`.
    - Same permissions as top-ups: the app reuses `puedeEditarRelleno()`.
    - Entered with "➕ Carga a tanque" (`#modal-carga-aceite`, `abrirModalCargaAceite()` / `guardarCargaAceite()` / `borrarCargaAceite()`).
  - **Readings:** `medicionesTanque()` gives the soundings that measured the tank, oldest first. Soundings that didn't measure it are skipped. Loads and top-ups count in a span when `fecha > desde && fecha <= hasta` (`enLapso()`).
  - **Cards:** one per oil tank, with its latest measured sounding and %.
  - **Reserve (`filasReserva()`):** one row per pair of consecutive measured soundings.
    - consumo = inicial + cargado − final; rellenos anotados = top-ups of the oils stored in that tank (`mant_aceites.tanque_id`); diferencia = consumo − anotados.
    - Red if consumo < 0. Yellow only if |diferencia| > `AVISO_RESERVA_LITROS` (10) **and** > `AVISO_RESERVA_PORC` (20 %) of consumo.
  - **System (`filasSistema()`):** one row per measured sounding.
    - pérdida aparente = anterior + cargado − actual.
    - Yellow > `PERDIDA_SISTEMA_AMARILLO` (5), red > `PERDIDA_SISTEMA_ROJO` (20), with "Posible pérdida en el sistema hidráulico".
  - **Drum/bucket oils** (no tank): monthly totals of top-ups per oil (`filasTamborPorMes()`).
  - **Layout:** `tablaConTarjetas()` draws each of these as a table on PC and as cards at 700 px or less, with the row tinted and a warning line.
  - **Excel:** `exportarRellenosExcel()` adds the sheets "Reserva TK x", "Sistema TK x", "Tambor-bidón por mes" and "Cargas a tanque" after the filtered "Rellenos" sheet. The rellenos filters don't affect these sheets.

### Photos

Section `============ FOTOS ============`. It's reusable: today it holds the ship photo, and later it will hold deficiencies.

- **Storage:**
  - The private Supabase Storage bucket `mant-fotos` only takes JPG up to 2 MB.
  - Paths are `empresa/barco/tipo/<uuid>.jpg`; the thumbnail is the same path ending in `_min.jpg` (`rutaMiniatura()`).
  - Policies on `storage.objects` use `mant_priv.foto_permitida(name, nivel)`: the company folder must be the ship's company, and the user needs that ship at the level. Viewing needs level 1; upload, overwrite and delete need 3 (jefe/admin) for every folder type. A new type that needs different rules (e.g. operador uploading deficiency photos) needs its own policy condition.
  - Storage doesn't allow deleting objects with SQL; use the Storage API (`sb.storage.from(...).remove`).
- **Helpers:**
  - `prepararFoto(archivo)` rejects non-images and files over `FOTO_MB_MAX` (15 MB), then resizes in the browser: longest side `FOTO_LADO_MAX` (1600), JPG quality from 0.8 down until it's ≤ `FOTO_KB_OBJETIVO` (300 KB), keeping the camera's orientation. It returns `{ grande, lienzo }`.
  - `elegirRecorteCircular(lienzo)` opens `#modal-recorte` (drag the circle, resize with the slider or the wheel) and returns `{x, y, lado}` or null. `miniaturaDesde(lienzo, recorte)` makes the 300×300 thumbnail.
  - `subirFoto(tipo, grande, mini)`, `reemplazarMiniatura()`, `borrarFoto()` and `urlFoto(ruta, miniatura)` (signed URLs, `FOTO_URL_SEGUNDOS` = 600, cached in `urlsFotos`).
  - `lienzoDeFoto()` downloads the big photo to re-crop. `abrirVisorFoto()` is the full-size viewer (`#visor-foto`, Esc closes it). `elegirArchivoFoto()` opens `#foto-input` (`accept="image/*"`: camera or gallery on a phone).
- **Ship photo:** `mant_buque.foto_ruta` holds the path of the big image.
  - Mi Barco shows it whole with a maximum height (`htmlFotoBarco()` / `cargarFotoBarco()`), with "Subir foto" / "Cambiar" / "Ajustar miniatura" / "Quitar" (jefe/admin).
  - The header shows the round thumbnail in `#header-foto` (`mostrarFotoEncabezado()`), or ⚓ if there's none.
  - `subirFotoBarco()` uploads the new photo, saves the path, then deletes the old one; if saving fails, it deletes the new upload. `ajustarMiniaturaBarco()` re-crops and overwrites only the thumbnail. `quitarFotoBarco()` clears the field, then deletes both files.

### Dates

Older code computes "today" with `new Date().toISOString().split('T')[0]`, which is UTC and rolls over to tomorrow after 21:00 in Uruguay (UTC-3). New code uses `hoyLocalISO()` and `sumarDias()` (defined in the Deficiencias section); prefer those for new date logic.

### Auth

Supabase email/password auth (`sb.auth`). `chequearSesion()` runs on load; `onAuthStateChange` hides the app back to the login overlay on `SIGNED_OUT`. There is no signup flow in the UI — accounts are provisioned directly in Supabase.

## Database schema

`docs/esquema.sql` documents all `mant_*` tables of `ncughlkgdgigwkggnxri` plus their indexes, functions/triggers and RLS policies, as of 2026-11-01. **Keep it in sync**: whenever you apply a migration, update the file too. The live Supabase project is the source of truth if they ever disagree. Tables added beyond the original six (besides `mant_empresas`, `mant_accesos` and `mant_perfiles`, described below):

- `mant_buque` — the ships table, one row per ship. `capacidad_combustible_litros` (nullable, ≥ 0) is the total tank capacity, edited in Mi Barco.
- `mant_equipos` — equipment fichas; includes `activo` (soft delete) and `critico boolean not null default false`.
- `mant_lecturas_horas` — `equipo` (text name), `fecha`, `horas_mes`, `hrs_total`.
- `mant_deficiencias` — `anio`, `numero` (unique together, set by trigger `mant_deficiencias_numerar`), `equipo_id` → `mant_equipos(id)`, `descripcion`, `fecha_detectada`, `detectada_por`, `critica`, `fecha_limite`, `estado` (`'abierta'|'cerrada'`), `fecha_cierre`, `accion_realizada`, `creado_en`.
- `mant_tripulantes` — `nombre`, `cargo`, `departamento` (`'Cubierta'|'Máquinas'`, inherited by their documents), `activo`.
- `mant_certificados` — `nombre`, `categoria`, `tripulante_id` → `mant_tripulantes(id)` (nullable; set ⇔ `categoria = 'Tripulación'`), `departamento`, `fecha_vencimiento` (nullable, see "Certificates without a date"), `dias_aviso` (default 30), `observaciones`, `activo`.
- `mant_certificados_historial` — `certificado_id` → `mant_certificados(id)`, `fecha_renovacion`, `vencimiento_anterior`, `vencimiento_nuevo`, `notas`; written only by `mant_certificados_renovar()`.
- `mant_tareas` and `mant_certificados` both have `postergada_hasta` + `motivo_postergacion` (both null or both set).
- `mant_tareas` extra columns: `equipo_id` → `mant_equipos(id)`, `tipo_trabajo` (check-constrained code, nullable), `cada_hrs` / `cada_meses` (control intervals). `unidad` also allows `'ambos'` and `'ninguna'`.
- `mant_combustible_periodos` — `desde`, `hasta`, `inicio_litros`, `fin_litros` (null = en curso), `horas_mmpp`, `horas_mga`, `millas`, `horas_navegacion`, `observaciones`, `creado_en/por`, `actualizado_en/por`; `unique (barco_id, id)`.
- `mant_combustible_cargas` — `periodo_id` → `mant_combustible_periodos(barco_id, id)` on delete cascade, `fecha`, `litros` (> 0), `proveedor`, `creado_en/por`.
- `mant_combustible_trasvases` — `origen_barco_id` / `destino_barco_id` → `mant_buque(id)` (one may be null), `otro_buque` (name, only when one side is null), `fecha`, `litros` (> 0), `notas`, `creado_en/por`, `actualizado_en/por`. It has no `barco_id`: it belongs to both ships.
- `mant_tanques` — `codigo` (unique per ship), `servicio` (check-constrained), `contenido`, `capacidad_litros` (> 0), `orden`, `activo`, `creado_en/por`, `actualizado_en/por`.
- `mant_sondas` — `fecha` (`unique (barco_id, fecha)`), `observaciones`, `creado_en/por`, `actualizado_en/por`.
- `mant_sondas_lecturas` — `sonda_id` → `mant_sondas(barco_id, id)` on delete cascade, `tanque_id` → `mant_tanques(barco_id, id)`, `litros` (≥ 0); `unique (sonda_id, tanque_id)`.
- `mant_aceites` — `nombre` (unique per ship), `tipo` (check-constrained), `tanque_id` → `mant_tanques(barco_id, id)` (null = tambor/bidón), `activo`, `creado_en/por`, `actualizado_en/por`.
- `mant_rellenos` — `fecha`, `equipo_id` → `mant_equipos(barco_id, id)`, `aceite_id` → `mant_aceites(barco_id, id)`, `litros` (> 0), `tipo` (`'Relleno'|'Cambio'`), `observaciones`, `creado_en/por`, `actualizado_en/por`.
- `mant_equipos.aceite_id` → `mant_aceites(barco_id, id)` (nullable): the equipment's oil.
- `mant_tanques.uso_aceite` — `'Reserva'|'Sistema'|null`, only on oil tanks.
- `mant_buque.foto_ruta` — path of the ship photo in the `mant-fotos` Storage bucket (see "Photos").
- `mant_cargas_aceite` — `fecha`, `tanque_id` → `mant_tanques(barco_id, id)` (oil tanks only), `litros` (> 0), `origen` (`'Proveedor'|'Tambor/bidón'`), `observaciones`, `creado_en/por`, `actualizado_en/por`.

Every `mant_*` table has RLS enabled, with policies by company, ship and role (see below). New `mant_*` tables need `barco_id` and the same kind of policies. Apply schema changes as migrations (`apply_migration`), then run the security advisors. Known pre-existing advisor warning: Auth's leaked password protection is disabled.

## Several ships, companies and roles

`localStorage` keys: `nav`, `cert-solapa`, `barco` (last ship) and `exportar-plan`.

- **Several ships:**
  - **Ships table:** `mant_buque` is the ships table, one row per ship (id 1 = B/M Santa Lucía).
  - **`barco_id`:** every other `mant_*` table has `barco_id not null` → `mant_buque(id)`.
  - **Mixing ships is blocked:** child tables reference their parent by `(barco_id, id)` composite foreign keys, so the database rejects rows that mix ships.
  - **Deficiency numbering** is per ship and per year.
  - **No default:** `barco_id` has no default, so a row the app forgets to tag fails instead of landing on the wrong ship.
  - **Gearboxes:** "Toma las horas de" (`mant_equipos.horas_de_id`) replaced the old hard-coded `CAJAS_POR_MP`. A piece of equipment can take its hours from another one on the same ship (enforced by a composite FK), and a trigger rejects loops and self-references.
- **Companies, users and roles:** the database no longer uses the old "only my email" policy.
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
  - The full rules are in `docs/esquema.sql`.
- **The app works per ship** (section `BARCOS Y ROLES` in `index.html`):
  - **Startup:** after login, `iniciarApp()` → `cargarBarcos()` reads the user's own `mant_accesos` rows and the ships they can see. It builds `barcosDisponibles` (each with the user's highest role there) and picks `barcoActual`, the last one used (`barco`) or the first. A user with no ships sees `#sin-barcos` and nothing else.
  - **Header:** the ship name comes from its ficha. With more than one ship it becomes a `<select id="sel-barco">`. Next to it is the role badge (`#header-rol`), and the tab title follows the ship. `cambiarBarco()` closes open modals and the equipment ficha, then reloads everything.
  - **Reads and writes:**
    - Every read in `cargarTodo()` filters `.eq('barco_id', B)` (`mant_buque` by `id`) and ignores a late answer for a ship that's no longer selected.
    - Every insert wraps its data in `conBarco()`.
    - The hour updates by equipment name also filter by `barco_id`.
  - **Hour cascading:** `equiposQueTomanHorasDe(nombre)` gives the equipment that receives a piece of equipment's hours (also down a chain), and `equiposOcultosCarga()` hides those from the hours form. The "Toma las horas de" select (`llenarSelectorHorasDe()`) leaves out the equipment itself and anything that already takes its hours.
  - **Excel files:**
    - **Names** carry the ship (`nombreBarcoArchivo()`) and go through `textoArchivo()`, so they have no accents, ñ, signs or spaces (`Stock_BM_Santa_Lucia_2026-10-29.xlsx`). `busquedaArchivo()` adds the search text.
    - **Plan export:** the Tareas tab's "📥 Exportar Excel" opens `#modal-export-plan` (`abrirExportarPlan()` / `exportarPlan()`). It offers all equipment or a choice grouped by ficha category, plan and/or history, all tasks or only overdue and upcoming ones (postponed included), and full history or a date range.
      - The last choice is kept in `exportar-plan`.
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
    - **After a password change:** Supabase closes every session, so `guardarMiClave()` signs in again by itself with the new password (`usuarioEmail`). `cambiandoClave` makes `onAuthStateChange` ignore `SIGNED_OUT` only during those seconds; "Salir" and a really expired session still go to the login. If the automatic sign-in fails, it shows "Contraseña cambiada: entrá de nuevo con la nueva" and the login.
    - The admin's own row has no actions.
  - **Service role:** the project's `service_role` had no table grants. It only gets `select` on `mant_accesos` and `select, insert, update` on `mant_perfiles`.

## Conventions

- UI text, comments, and variable/function names are in Spanish (matching the vessel's crew); keep new code consistent with that.
- No dependency manager — new third-party libs are added as CDN `<script>` tags in `<head>`.
- XSS: any user-supplied string interpolated into `innerHTML` must go through `escape()`.
