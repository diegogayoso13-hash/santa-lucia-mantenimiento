# Mudanza a la base nueva (hora cero)

Paso a paso para pasar la app real del proyecto Supabase viejo (`zfoetyauhauztkkltjaz`) al nuevo
(`ncughlkgdgigwkggnxri`, "Mantenimiento Naval"), que ya está preparado para varios barcos.

**Regla de oro:** en el proyecto viejo solo se LEE. Lo comparte otra app en uso: no se borra, no se
cambia y no se le tocan permisos, ni durante la mudanza ni después.

Duración estimada: 30 a 45 minutos.

## Qué hay y dónde

Todo lo de la mudanza vive **fuera del repositorio**, en `C:\Users\Usuario\mudanza-santa-lucia\`.
Los datos nunca se suben a GitHub.

| Archivo | Para qué |
|---|---|
| `exportar.html` | Página que se abre en el navegador. Entra al proyecto viejo con tu usuario, baja las 13 tablas `mant_*` completas (de a 1000 filas) y descarga `mant_export_AAAA-MM-DD_HHMM.json`. Solo lee. |
| `conexion.txt` | Cadena de conexión (Session pooler) de la base **nueva**, con su contraseña. No se comparte ni se sube a ningún lado. |
| `cargar.js` | Carga el export en la base nueva y verifica tabla por tabla. Todo en una sola transacción: si algo falla, la base queda como estaba. |
| `tablero.js` | Compara los números del tablero de la app real (sobre el export) con los de la app de prueba (sobre la base nueva), cada una con sus propias funciones. |
| `pasar_a_raiz.js` | Arma el `index.html` definitivo a partir de `prueba/index.html`. |
| `node_modules/`, `package.json` | El conector de Postgres (`pg`) que usan los scripts. |

Hace falta Node.js instalado (ya está).

### Qué hace `cargar.js`

1. Apaga los triggers propios de las tablas de datos y de `mant_buque`, para que no renumeren
   deficiencias ni cambien fechas, autor o departamento. Las claves foráneas y los `check` siguen activos.
2. Borra todas las filas de las tablas de datos: equipos, tareas, historial, repuestos,
   tarea_repuestos, movimientos, herramientas, lecturas, deficiencias, tripulantes, certificados y
   renovaciones.
3. **Mantiene** `mant_empresas`, `mant_accesos`, `mant_perfiles`, los usuarios y la fila del Santa
   Lucía (`mant_buque.id = 1`). La ficha de esa fila se actualiza con los datos del viejo, menos
   `empresa_id`.
4. Inserta todas las filas con los **mismos id**, `barco_id = 1` y las fechas originales
   (`creado_en`, `actualizado_en`, `fecha`…). Entran los movimientos y los registros dados de baja.
   `creado_por` y `cerrada_por` quedan vacíos, porque el viejo no los tenía.
5. Pone "Toma las horas de" en las 2 cajas reductoras: Caja Reductora Babor toma de Motor Principal
   Babor, y Estribor de Estribor.
6. Pone cada contador de id (secuencia) en el máximo de su tabla.
7. Vuelve a prender los triggers, confirma la transacción y verifica:
   - cantidad de filas del viejo, del nuevo y del total de la tabla;
   - todas las columnas de todas las filas comparadas una por una, más una huella (md5) por tabla;
   - cajas enlazadas, contadores de id, que no quede ningún trigger apagado, y que sigan las
     empresas, accesos, perfiles y el barco.

   El detalle queda en `verificacion_<export>.json`.

## Ensayo general (1/11/2026)

Hecho sobre la base nueva con `mant_export_2026-11-01_2227.json`. Todo coincidió:

- Las 13 tablas tienen las mismas filas y el mismo contenido, con 0 diferencias en todas las columnas.
- Las dos cajas quedaron enlazadas y los contadores de id quedaron bien.
- Los números del tablero son iguales en las dos apps.

El viejo no tenía equipos ni certificados dados de baja; solo 2 tareas dadas de baja, que se cargaron.

## Hora cero, paso a paso

### Antes (el día anterior)

1. Avisar a quienes usan la app que durante la mudanza **no carguen nada**: ni horas, ni registros,
   ni stock.
2. Comprobar que `conexion.txt` sigue sirviendo. Por ejemplo, correr
   `node cargar.js --verificar`, que solo lee.

### 1. Marcar el punto de vuelta atrás (git)

En la carpeta del repositorio:

```
git checkout main
git pull
git tag antes-mudanza
git push origin antes-mudanza
```

Esa etiqueta es la versión que funciona con la base vieja.

### 2. Congelar y exportar el viejo

1. Confirmar que nadie está usando la app.
2. Abrir `C:\Users\Usuario\mudanza-santa-lucia\exportar.html`, entrar y descargar.
   **Todas las tablas tienen que tener ✓.**
3. Mover el `.json` de `C:\Users\Usuario\Downloads` a `C:\Users\Usuario\mudanza-santa-lucia\`.

### 3. Cargar y verificar la base nueva

En `C:\Users\Usuario\mudanza-santa-lucia\`:

```
node cargar.js
node tablero.js
```

- `cargar.js` usa el export más reciente de la carpeta. Todas las filas de la tabla tienen que decir
  `ok: SI`, y "Triggers apagados" tiene que decir `ninguno`.
- `tablero.js`: todas las filas tienen que decir `igual: SI`.
- Revisar los avisos de seguridad de Supabase del proyecto nuevo. Lo único conocido es "Leaked
  password protection disabled".

**Si algo dice NO, parar acá.** La app real sigue en la base vieja y no pasó nada.

### 4. Pasar la app de prueba a la raíz

```
node C:\Users\Usuario\mudanza-santa-lucia\pasar_a_raiz.js C:\Users\Usuario\OneDrive\Escritorio\santa-lucia-app
```

Escribe el `index.html` de la raíz a partir de `prueba/index.html`:

- sin la franja naranja (el CSS y el `<div>`);
- sin "[PRUEBA]" en los títulos;
- con las claves del navegador sin el prefijo `prueba-`: `nav`, `cert-solapa`, `barco` y
  `exportar-plan`;
- con los íconos en `icons/` en lugar de `../icons/`.

Si queda algo de "prueba", no escribe nada y avisa. El `manifest.webmanifest` de la raíz no se
toca: ya tiene el nombre normal ("Mantenimiento").

Después, en el mismo cambio:

1. **Borrar la carpeta `prueba/`** con `git rm -r prueba`. Apunta a la misma base, que desde ahora
   es la real, así que dejarla publicada sería una segunda puerta a los datos reales con un cartel
   que dice "no cargar datos reales". Si más adelante hace falta una versión de prueba, se arma con
   un proyecto Supabase nuevo y separado.
2. Documentación:
   - `docs/esquema.sql` pasa a ser el contenido de `docs/esquema_prueba.sql`, y este último se borra.
   - Actualizar `CLAUDE.md`: la app real es la de varios barcos y ya no hay `prueba/`.
3. Commit y push a `main`.

### 5. Comprobar en vivo

1. Esperar a que GitHub Pages publique (1 a 2 minutos).
2. Abrir la app y recargar sin caché (Ctrl+F5; en el celular, cerrarla del todo y volver a abrirla).
3. Entrar y comprobar:
   - que no hay franja;
   - que el tablero muestra los mismos números que dio `tablero.js`;
   - que el historial de un equipo se ve completo;
   - que se puede registrar algo de prueba (y borrarlo).
4. Pedir a todos que cierren y vuelvan a abrir la app. Así nadie sigue con la versión vieja
   abierta, que todavía escribiría en la base vieja.

### 6. Después

1. Al día siguiente, volver a abrir `exportar.html` (solo lee) y comparar las cantidades con las
   del export de la hora cero. Si alguna subió, alguien cargó algo en la base vieja con una pestaña
   vieja: pasarlo a mano a la app nueva.
2. Cambiar la contraseña de la base nueva (Project Settings → Database → Reset database password)
   y borrar `conexion.txt`. Guardar el export de la hora cero como respaldo.
3. Crear en el Admin los usuarios de la tripulación que hagan falta. Hoy la base nueva tiene solo
   el usuario dueño.
4. El proyecto viejo **no se toca**: la otra app lo sigue usando y las tablas `mant_*` quedan ahí
   como respaldo.

## Volver atrás (en minutos)

La base vieja queda intacta y la etiqueta `antes-mudanza` tiene la app que la usa.

- **Si falla antes del push (pasos 1 a 4):** no hay nada que deshacer. La app real nunca dejó de
  usar la base vieja.
- **Si falla después del push:**
  1. Deshacer el commit de la mudanza sin borrar historia:
     ```
     git revert --no-edit <commit de la mudanza>
     git push
     ```
     Otra forma de volver a la etiqueta:
     `git checkout antes-mudanza -- . && git commit -m "Vuelve a la base vieja" && git push`.
  2. Esperar a que GitHub Pages publique (1 a 2 minutos) y pedir a todos que recarguen la app.
  3. Lo que se haya cargado en la base nueva después de la hora cero no está en la vieja. Para
     verlo, en el SQL editor del proyecto nuevo:
     ```sql
     select 'historial' t, id, creado_en from mant_historial where creado_en > '<hora cero UTC>'
     union all select 'lecturas', id, creado_en from mant_lecturas_horas where creado_en > '<hora cero UTC>'
     union all select 'deficiencias', id, creado_en from mant_deficiencias where creado_en > '<hora cero UTC>'
     union all select 'movimientos', id, fecha from mant_movimientos where fecha > '<hora cero UTC>'
     order by 3;
     ```
     Y para cambios de stock, tareas o fichas, buscar `actualizado_en > '<hora cero UTC>'` en
     `mant_repuestos`, `mant_tareas`, `mant_equipos` y `mant_certificados`. Volver a cargarlo a
     mano en la app vieja.
  4. Arreglar el problema con calma y repetir la hora cero desde el paso 2. `cargar.js` borra y
     vuelve a cargar todo, así que se puede correr las veces que haga falta.
