# Guía paso a paso — AutoAudit

Esta guía explica qué hacer con cada archivo, en orden, desde cero hasta la entrega.

---

## Opción rápida: Windows con PostgreSQL ya instalado (pgAdmin)

1. **Python:** instálalo desde https://www.python.org/downloads/ y marca **"Add python.exe to PATH"**.
2. **Descomprime** `autoaudit.zip` (por ejemplo en `Documentos\autoaudit`).
3. Doble clic en **`instalar_windows.bat`**. Te pide la contraseña del usuario `postgres`
   (la misma que usas en pgAdmin). Crea la base `autoaudit_db`, el generador, la tienda de ejemplo
   y el entorno de Python.
4. Doble clic en **`iniciar_windows.bat`**. Se abre `http://localhost:8000`.
   **No cierres esa ventana negra** mientras usas la aplicación; si la cierras, el navegador mostrará
   "localhost rechazó la conexión".
5. Pruebas: doble clic en `pruebas\ejecutar_pruebas_windows.bat`.
6. En pgAdmin: refresca **Servers → PostgreSQL → Databases** y verás `autoaudit_db`
   (esquemas `auditoria` y `tienda`).

Desde aquí, sigue en el **Paso 4** (recorrido por la aplicación). Los pasos 0 a 3 son para Ubuntu,
que es la plataforma que pide el enunciado.

---

## Paso 0. Preparar la PC

El proyecto exige **Ubuntu 26.04 LTS** y **PostgreSQL 18**.

- **Si tu PC ya tiene Ubuntu 26.04:** continúa al Paso 1.
- **Si tu PC tiene Windows:** instala Ubuntu con WSL. Abre PowerShell como administrador y ejecuta
  `wsl --install -d Ubuntu-26.04` (o instala "Ubuntu 26.04" desde Microsoft Store), reinicia, crea tu usuario
  de Ubuntu y trabaja dentro de esa terminal. La aplicación se abre igual en tu navegador de Windows en
  `http://localhost:8000`.
- **Alternativa:** una máquina virtual (VirtualBox) con Ubuntu 26.04.

## Paso 1. Copiar el proyecto

1. Descomprime `autoaudit.zip` en tu carpeta personal, por ejemplo `~/autoaudit`.
   (En WSL puedes copiarlo desde Windows: `cp /mnt/c/Users/TU_USUARIO/Downloads/autoaudit.zip ~ && cd ~ && unzip autoaudit.zip`.)
2. Entra a la carpeta: `cd ~/autoaudit`

## Paso 2. Instalar todo con un comando

```bash
sudo bash install.sh
```

Qué hace, en este orden:

1. Instala PostgreSQL (Ubuntu 26.04 trae la versión 18) y Python.
2. Ejecuta `sql/instalar_bd.sh`, que corre los scripts `sql/00` a `sql/09` en orden:
   roles y usuarios, tablas de auditoría, vistas del diccionario, funciones de configuración,
   generador de triggers, consultas, seguridad, event triggers, base de ejemplo "tienda" y comentarios.
3. Ejecuta `ejemplos/01_configurar_demo.sql` (configura la auditoría de las 4 tablas de la tienda) y
   `ejemplos/02_generar_actividad.sql` (simula cambios de varios usuarios), para que tengas datos que mostrar.
   Si prefieres empezar vacío: `sudo bash install.sh --sin-demo`.
4. Crea el entorno Python en `app/.venv` e instala FastAPI, psycopg, openpyxl y reportlab.
5. Muestra una tabla con el estado de la auditoría (debe decir ACTIVO y `sincronizado = t`).

Los scripts son repetibles: si algo falla puedes corregirlo y volver a ejecutar `sudo bash install.sh`.

## Paso 3. Correr la aplicación

```bash
bash run.sh
```

Abre `http://localhost:8000` (se abre solo si tienes escritorio). Para detenerla: `Ctrl + C`.
Para que otros equipos de la red entren: `bash run.sh --red` y usan `http://IP-DE-TU-PC:8000`.

## Paso 4. Recorrido por la aplicación (guion de demostración)

1. **Inicia sesión como `admin_auditoria` / `Admin123!`** (botones de acceso rápido en la pantalla de login).
2. **Panel:** indicadores, gráfica por día y últimas operaciones. Clic en una fila → detalle completo.
3. **Configuración:**
   - Izquierda: tablas leídas del diccionario de datos de PostgreSQL.
   - Elige `tienda.productos`: verás cada columna con su tipo, PK/FK y casillas INSERT / UPDATE / DELETE.
   - Marca por ejemplo `categoria` en UPDATE y pulsa **Guardar y generar trigger**: aparece el código SQL
     generado automáticamente. **Ver código SQL** lo muestra en cualquier momento.
   - **Desactivar** quita el trigger (se conserva la bitácora); **Activar** lo regenera.
4. **Datos (simulador):** modifica registros de la tienda. Cierra sesión y entra como `vendedor`:
   cambia el límite de crédito de un cliente. Intenta editar `tienda.empleados`: PostgreSQL lo rechaza
   (permisos reales).
5. Vuelve como `auditor` / `Auditor123!` (solo consulta):
   - **Bitácora:** filtra por usuario, tabla, columna, operación y fechas; exporta a **CSV, Excel o PDF**.
     Clic en una fila → fila completa antes/después, IP, equipo y la historia del registro.
   - **Por usuario:** tarjetas con el resumen y el historial completo de cada usuario.
   - **Por columna:** línea de tiempo de los valores de una columna (ej. `tienda.productos.precio`).
   - **Registro del generador:** cada generación, error, y cambio DDL detectado.
   - **Parámetros:** privacidad de IP y retención; estaciones de trabajo registradas.
6. Prueba que un usuario de solo consulta no puede configurar: como `auditor` la pantalla Configuración es de lectura.

## Paso 5. Ejecutar las pruebas de validación

```bash
sudo bash pruebas/ejecutar_pruebas.sh            # todas (≈1 minuto, incluye rendimiento)
sudo bash pruebas/ejecutar_pruebas.sh --rapido   # sin la de rendimiento
```

| Archivo | Qué prueba |
|---|---|
| `00_preparar.sql` | Crea el esquema `pruebas` y una tabla `cuenta` auditada |
| `01_prueba_insert.sql` | INSERT registrado con usuario, estación, llave y solo columnas configuradas |
| `02_prueba_update.sql` | UPDATE guarda valor antiguo y nuevo; no registra si no hay cambio real |
| `03_prueba_delete.sql` | DELETE preserva la fila completa aunque el registro ya no exista |
| `04_prueba_seguridad.sql` | Permisos, bitácora inmutable, validaciones, RENAME/DROP COLUMN, consultas |
| `05_prueba_rendimiento.sql` | 1.000 / 10.000 / 50.000 filas con y sin auditoría |

Debe terminar con **TODAS LAS PRUEBAS PASARON (39)**.

> Las pruebas dejan sus registros en la bitácora (que es inmutable; ese es el punto). Si vas a presentar la
> aplicación con datos limpios, reinstala antes: `sudo -u postgres dropdb autoaudit_db && sudo bash install.sh`.

## Paso 6. Usar el sistema desde SQL (opcional, útil para explicar)

```bash
psql -h 127.0.0.1 -U admin_auditoria -d autoaudit_db       # contraseña Admin123!
```

```sql
SELECT * FROM auditoria.v_dic_tablas;                                   -- diccionario
SELECT auditoria.fn_configurar_columna('tienda','clientes','direccion', true, true, true);
SELECT auditoria.fn_generar_trigger(1);                                 -- aplica
SELECT * FROM auditoria.v_estado_auditoria;                             -- estado real
SELECT * FROM auditoria.fn_historial_usuario('vendedor');               -- por usuario
SELECT * FROM auditoria.fn_historial_columna('tienda','productos','precio');  -- por columna
```

Más ejemplos en `ejemplos/03_consultas_ejemplo.sql`
(`psql -h 127.0.0.1 -U auditor -d autoaudit_db -f ejemplos/03_consultas_ejemplo.sql`).

## Paso 7. Documentación técnica (PDF)

`docs/Documentacion_Tecnica.pdf` ya contiene: diagrama entidad-relación, diccionario de datos, manual de
configuración, procedimiento de instalación, seguridad y resultados de pruebas.

Para regenerarla en tu PC con **tu nombre**, la versión de PostgreSQL 18 y tus propios resultados de pruebas
(ejecuta antes el Paso 5):

```bash
sudo apt install -y chromium     # solo si no tienes Chrome/Chromium (para crear el PDF)
app/.venv/bin/python docs/generar_documentacion.py --estudiante "Tu Nombre" --carne "0900-XX-XXXXX"
```

Si no tienes Chrome, abre `docs/Documentacion_Tecnica.html` en el navegador → Imprimir → Guardar como PDF.
Otros archivos: `docs/diagrama_er.png` (imagen del E-R), `docs/diagrama_er.dot` (fuente Graphviz) y
`docs/diccionario_datos.sql` (consulta que imprime el diccionario desde PostgreSQL).

## Paso 8. Subir a GitHub (entregable "código fuente")

```bash
cd ~/autoaudit
git init
git add .
git commit -m "AutoAudit: sistema de auditoría automatizado"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/autoaudit.git   # crea antes el repo vacío en github.com
git push -u origin main
```

El archivo `.gitignore` ya excluye `app/.venv` y `app/.env`. Entrega el enlace del repositorio.

## Paso 9. Cómo funciona por dentro (para defender el proyecto)

1. **Configuración** (`03_funciones_config.sql`): cada función valida contra `pg_catalog` que la tabla y la
   columna existan, guarda la tabla por su **OID** y la columna por su **attnum** (así sobreviven a un RENAME).
2. **Generador** (`04_generador_triggers.sql`): `fn_construir_sql_trigger` arma con `format()` una función
   PL/pgSQL **exclusiva** de esa tabla, con las columnas y eventos escritos dentro del código. El trigger usa
   `AFTER INSERT OR UPDATE OF col1, col2 OR DELETE`, de modo que no se dispara si solo cambian columnas no
   auditadas, y compara con `IS DISTINCT FROM` para registrar solo cambios reales.
   `fn_generar_trigger` lo ejecuta dentro de un bloque con manejo de errores: si falla, se revierte, la tabla
   queda en ERROR y el error se guarda en `log_generacion`.
3. **Bitácora**: un `bitacora_encabezado` por fila afectada (usuario, estación, fecha, transacción, llave y fila
   completa antes/después en jsonb) y un `bitacora_detalle` por columna (valor anterior y nuevo), que referencia
   la `configuracion_auditoria` usada.
4. **Seguridad**: los triggers generados pertenecen a `autoaudit_owner`, único rol con permiso de INSERT en la
   bitácora. Nadie puede modificarla ni borrarla (trigger `trg_proteger`). El usuario se toma de `session_user`
   y la IP de `inet_client_addr()`, que el cliente no puede falsificar.
5. **Dependencias** (`07_eventos_ddl.sql`): event triggers detectan `DROP TABLE` (configuración HUERFANA,
   historial conservado), `DROP COLUMN ... CASCADE` y `ALTER TABLE`, y regeneran el trigger automáticamente.
   PostgreSQL además impide borrar una columna auditada sin CASCADE.
6. **Aplicación web** (`app/main.py`): cada usuario inicia sesión con su usuario de PostgreSQL y todas las
   operaciones se ejecutan con esa conexión; por eso los permisos los decide la base de datos y la bitácora
   registra al usuario real. La aplicación informa el equipo (`autoaudit.equipo`) y el nombre de aplicación.

## Problemas comunes

| Síntoma | Solución |
|---|---|
| Windows: "localhost rechazó la conexión" | La ventana de `iniciar_windows.bat` está cerrada; vuelve a abrirla |
| `No se pudo conectar a PostgreSQL` | `sudo systemctl start postgresql` |
| `password authentication failed` | Revisa usuario/contraseña de la tabla del Paso 4 |
| El puerto 8000 está ocupado | `PUERTO=8080 bash run.sh` |
| Quiero empezar de cero | `sudo -u postgres dropdb autoaudit_db && sudo bash install.sh` |
| En WSL `systemctl` no funciona | `sudo service postgresql start` |
| Cambiar contraseñas | `sudo -u postgres psql -c "ALTER ROLE admin_auditoria PASSWORD 'nueva'"` |
