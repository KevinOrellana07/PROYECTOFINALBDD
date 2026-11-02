-- =====================================================================
-- AutoAudit - 01_esquema.sql : Estructura de tablas del sistema
-- Ejecutar como superusuario en la BD autoaudit_db:
--     sudo -u postgres psql -d autoaudit_db -f sql/01_esquema.sql
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS auditoria;
COMMENT ON SCHEMA auditoria IS 'AutoAudit: configuración, generador de triggers y bitácora';

-- ---------------------------------------------------------------------
-- Catálogo: EVENTO  (INSERT / UPDATE / DELETE)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.evento (
    evento_id    smallint     PRIMARY KEY,
    codigo       varchar(10)  NOT NULL UNIQUE
                 CHECK (codigo IN ('INSERT','UPDATE','DELETE')),
    descripcion  varchar(100) NOT NULL
);
COMMENT ON TABLE auditoria.evento IS 'Catálogo de operaciones DML que pueden auditarse';

INSERT INTO auditoria.evento VALUES
    (1, 'INSERT', 'Inserción de un registro nuevo'),
    (2, 'UPDATE', 'Modificación de un registro existente'),
    (3, 'DELETE', 'Eliminación de un registro')
ON CONFLICT (evento_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- TABLA_AUDITADA : tablas del diccionario habilitadas para auditoría
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.tabla_auditada (
    tabla_id          serial       PRIMARY KEY,
    tabla_oid         oid          NOT NULL UNIQUE,         -- OID real en pg_class
    esquema           name         NOT NULL,
    tabla             name         NOT NULL,
    descripcion       varchar(250),
    activa            boolean      NOT NULL DEFAULT true,   -- interruptor maestro
    estado            varchar(15)  NOT NULL DEFAULT 'PENDIENTE'
                      CHECK (estado IN ('PENDIENTE','ACTIVO','INACTIVO','ERROR','HUERFANA')),
    funcion_trigger   name,                                  -- función generada
    trigger_nombre    name,                                  -- trigger generado
    sql_generado      text,                                  -- último código generado
    fecha_generacion  timestamptz,
    ultimo_error      text,
    creado_por        name         NOT NULL DEFAULT session_user,
    fecha_creacion    timestamptz  NOT NULL DEFAULT now(),
    modificado_por    name,
    fecha_modificacion timestamptz
);
-- Una tabla eliminada (HUERFANA) conserva su historial; si se vuelve a crear
-- con el mismo nombre se registra como una configuración nueva.
CREATE UNIQUE INDEX IF NOT EXISTS uq_tabla_auditada_nombre
    ON auditoria.tabla_auditada (esquema, tabla) WHERE estado <> 'HUERFANA';
COMMENT ON TABLE auditoria.tabla_auditada IS 'Tablas origen configuradas para auditoría (una fila = un trigger)';

-- ---------------------------------------------------------------------
-- COLUMNA_AUDITADA : columnas seleccionadas dentro de cada tabla
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.columna_auditada (
    columna_id     serial       PRIMARY KEY,
    tabla_id       integer      NOT NULL
                   REFERENCES auditoria.tabla_auditada(tabla_id) ON DELETE CASCADE,
    columna        name         NOT NULL,
    attnum         smallint     NOT NULL,           -- posición física (sobrevive a RENAME)
    tipo_dato      text         NOT NULL,
    activa         boolean      NOT NULL DEFAULT true,
    eliminada      boolean      NOT NULL DEFAULT false, -- la columna ya no existe en origen
    fecha_creacion timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_columna_auditada UNIQUE (tabla_id, attnum)
);
COMMENT ON TABLE auditoria.columna_auditada IS 'Columnas de cada tabla auditada';

-- ---------------------------------------------------------------------
-- CONFIGURACION_AUDITORIA : qué eventos se registran por columna
--   (columna x evento) -> activo
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.configuracion_auditoria (
    configuracion_id serial      PRIMARY KEY,
    columna_id       integer     NOT NULL
                     REFERENCES auditoria.columna_auditada(columna_id) ON DELETE CASCADE,
    evento_id        smallint    NOT NULL REFERENCES auditoria.evento(evento_id),
    activo           boolean     NOT NULL DEFAULT true,
    fecha_creacion   timestamptz NOT NULL DEFAULT now(),
    fecha_modificacion timestamptz,
    CONSTRAINT uq_configuracion UNIQUE (columna_id, evento_id)
);
COMMENT ON TABLE auditoria.configuracion_auditoria IS 'Eventos a auditar por cada columna de cada tabla';

-- ---------------------------------------------------------------------
-- USUARIO_AUDITADO : usuarios de BD que han provocado cambios
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.usuario_auditado (
    usuario_id      serial      PRIMARY KEY,
    nombre_usuario  name        NOT NULL UNIQUE,      -- session_user de PostgreSQL
    primera_actividad timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE auditoria.usuario_auditado IS 'Usuarios de base de datos detectados en la bitácora';

-- ---------------------------------------------------------------------
-- ESTACION_TRABAJO : origen de la conexión (IP + equipo + aplicación)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.estacion_trabajo (
    estacion_id     serial       PRIMARY KEY,
    direccion_ip    varchar(64)  NOT NULL,   -- texto: admite 'local' o IP anonimizada
    equipo          varchar(128) NOT NULL DEFAULT 'desconocido',
    aplicacion      varchar(128) NOT NULL DEFAULT 'desconocida',
    primera_actividad timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_estacion UNIQUE (direccion_ip, equipo, aplicacion)
);
COMMENT ON TABLE auditoria.estacion_trabajo IS 'Estaciones de trabajo desde donde se originan los cambios';

-- ---------------------------------------------------------------------
-- BITACORA_ENCABEZADO : un registro por fila afectada (operación)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.bitacora_encabezado (
    encabezado_id     bigserial    PRIMARY KEY,
    fecha_hora        timestamptz  NOT NULL DEFAULT clock_timestamp(),
    tabla_id          integer      NOT NULL
                      REFERENCES auditoria.tabla_auditada(tabla_id) ON DELETE RESTRICT,
    evento_id         smallint     NOT NULL REFERENCES auditoria.evento(evento_id),
    usuario_id        integer      NOT NULL REFERENCES auditoria.usuario_auditado(usuario_id),
    estacion_id       integer      NOT NULL REFERENCES auditoria.estacion_trabajo(estacion_id),
    usuario_aplicacion varchar(128),           -- usuario de la app (si la app lo informa)
    transaccion_id    bigint       NOT NULL DEFAULT txid_current(),
    llave_registro    jsonb,                   -- PK del registro afectado
    datos_anteriores  jsonb,                   -- fila completa ANTES (UPDATE/DELETE)
    datos_nuevos      jsonb                    -- fila completa DESPUÉS (INSERT/UPDATE)
);
COMMENT ON TABLE auditoria.bitacora_encabezado IS
  'Bitácora: una fila por registro afectado. Conserva la fila completa aunque el origen sea eliminado';

-- ---------------------------------------------------------------------
-- BITACORA_DETALLE : un registro por columna auditada afectada
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.bitacora_detalle (
    detalle_id        bigserial PRIMARY KEY,
    encabezado_id     bigint    NOT NULL
                      REFERENCES auditoria.bitacora_encabezado(encabezado_id) ON DELETE RESTRICT,
    configuracion_id  integer   NOT NULL
                      REFERENCES auditoria.configuracion_auditoria(configuracion_id) ON DELETE RESTRICT,
    columna_id        integer   NOT NULL
                      REFERENCES auditoria.columna_auditada(columna_id) ON DELETE RESTRICT,
    valor_anterior    text,
    valor_nuevo       text
);
COMMENT ON TABLE auditoria.bitacora_detalle IS 'Bitácora: valor anterior y nuevo por columna afectada';

-- Índices para consultas históricas
CREATE INDEX IF NOT EXISTS ix_enc_fecha          ON auditoria.bitacora_encabezado (fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_enc_usuario_fecha  ON auditoria.bitacora_encabezado (usuario_id, fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_enc_tabla_fecha    ON auditoria.bitacora_encabezado (tabla_id, fecha_hora DESC);
CREATE INDEX IF NOT EXISTS ix_enc_estacion       ON auditoria.bitacora_encabezado (estacion_id);
CREATE INDEX IF NOT EXISTS ix_enc_llave          ON auditoria.bitacora_encabezado USING gin (llave_registro);
CREATE INDEX IF NOT EXISTS ix_det_encabezado     ON auditoria.bitacora_detalle (encabezado_id);
CREATE INDEX IF NOT EXISTS ix_det_columna        ON auditoria.bitacora_detalle (columna_id, encabezado_id);
CREATE INDEX IF NOT EXISTS ix_det_configuracion  ON auditoria.bitacora_detalle (configuracion_id);

-- ---------------------------------------------------------------------
-- LOG_GENERACION : historial de generación/eliminación de triggers
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.log_generacion (
    log_id      bigserial   PRIMARY KEY,
    fecha_hora  timestamptz NOT NULL DEFAULT clock_timestamp(),
    tabla_id    integer     REFERENCES auditoria.tabla_auditada(tabla_id) ON DELETE SET NULL,
    objeto      text,
    accion      varchar(20) NOT NULL,   -- GENERAR, ELIMINAR, SINCRONIZAR, VALIDAR, DDL
    exito       boolean     NOT NULL,
    mensaje     text,
    sql_ejecutado text,
    usuario     name        NOT NULL DEFAULT session_user
);
COMMENT ON TABLE auditoria.log_generacion IS 'Registro de acciones del generador de triggers y errores';

-- ---------------------------------------------------------------------
-- PARAMETRO : opciones globales del sistema
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria.parametro (
    clave        varchar(50)  PRIMARY KEY,
    valor        varchar(200) NOT NULL,
    descripcion  varchar(300)
);
COMMENT ON TABLE auditoria.parametro IS 'Parámetros globales: privacidad de IP y retención';

INSERT INTO auditoria.parametro VALUES
    ('ip_modo', 'completa',
     'Tratamiento de la IP origen (privacidad): completa | anonimizada | ninguna'),
    ('dias_retencion', '365',
     'Días que se conservan los registros de bitácora (usado por fn_purgar_bitacora)')
ON CONFLICT (clave) DO NOTHING;
