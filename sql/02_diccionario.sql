-- =====================================================================
-- AutoAudit - 02_diccionario.sql : Consultas al diccionario de datos
-- Fuente: catálogo del sistema de PostgreSQL (pg_catalog).
-- Se excluyen esquemas del sistema y el propio esquema "auditoria".
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Tablas disponibles para auditar
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_dic_tablas AS
SELECT  c.oid                                   AS tabla_oid,
        n.nspname                               AS esquema,
        c.relname                               AS tabla,
        obj_description(c.oid, 'pg_class')      AS comentario,
        pg_get_userbyid(c.relowner)             AS propietario,
        GREATEST(c.reltuples, 0)::bigint        AS filas_estimadas,
        pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano,
        (SELECT count(*) FROM pg_attribute a
          WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS num_columnas,
        EXISTS (SELECT 1 FROM pg_constraint k
                 WHERE k.conrelid = c.oid AND k.contype = 'p')               AS tiene_pk,
        ta.tabla_id,
        COALESCE(ta.estado, 'NO CONFIGURADA')   AS estado_auditoria
FROM    pg_class c
JOIN    pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN auditoria.tabla_auditada ta ON ta.tabla_oid = c.oid
WHERE   c.relkind IN ('r', 'p')                     -- tablas normales y particionadas
  AND   n.nspname NOT IN ('pg_catalog', 'information_schema', 'auditoria', 'pg_toast')
  AND   n.nspname NOT LIKE 'pg_temp%'
  AND   NOT c.relispartition;                       -- se audita la tabla padre
COMMENT ON VIEW auditoria.v_dic_tablas IS 'Diccionario: tablas de usuario existentes';

-- ---------------------------------------------------------------------
-- Columnas de cada tabla
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_dic_columnas AS
SELECT  c.oid                                        AS tabla_oid,
        n.nspname                                    AS esquema,
        c.relname                                    AS tabla,
        a.attnum                                     AS posicion,
        a.attname                                    AS columna,
        format_type(a.atttypid, a.atttypmod)         AS tipo_dato,
        NOT a.attnotnull                             AS admite_nulos,
        pg_get_expr(d.adbin, d.adrelid)              AS valor_defecto,
        col_description(c.oid, a.attnum)             AS comentario,
        EXISTS (SELECT 1 FROM pg_constraint k
                 WHERE k.conrelid = c.oid AND k.contype = 'p'
                   AND a.attnum = ANY (k.conkey))    AS es_pk,
        EXISTS (SELECT 1 FROM pg_constraint k
                 WHERE k.conrelid = c.oid AND k.contype = 'f'
                   AND a.attnum = ANY (k.conkey))    AS es_fk,
        ca.columna_id,
        COALESCE(ca.activa AND NOT ca.eliminada, false) AS auditada
FROM    pg_attribute a
JOIN    pg_class c      ON c.oid = a.attrelid
JOIN    pg_namespace n  ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef d  ON d.adrelid = a.attrelid AND d.adnum = a.attnum
LEFT JOIN auditoria.tabla_auditada ta   ON ta.tabla_oid = c.oid
LEFT JOIN auditoria.columna_auditada ca ON ca.tabla_id = ta.tabla_id AND ca.attnum = a.attnum
WHERE   c.relkind IN ('r', 'p')
  AND   a.attnum > 0
  AND   NOT a.attisdropped
  AND   n.nspname NOT IN ('pg_catalog', 'information_schema', 'auditoria', 'pg_toast')
  AND   n.nspname NOT LIKE 'pg_temp%';
COMMENT ON VIEW auditoria.v_dic_columnas IS 'Diccionario: columnas de las tablas de usuario';

-- ---------------------------------------------------------------------
-- Llaves primarias y foráneas
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_dic_llaves AS
SELECT  n.nspname                         AS esquema,
        c.relname                         AS tabla,
        k.conname                         AS restriccion,
        CASE k.contype WHEN 'p' THEN 'PRIMARY KEY'
                       WHEN 'f' THEN 'FOREIGN KEY'
                       WHEN 'u' THEN 'UNIQUE' END AS tipo,
        (SELECT string_agg(a.attname, ', ' ORDER BY x.ord)
           FROM unnest(k.conkey) WITH ORDINALITY x(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.attnum) AS columnas,
        k.confrelid::regclass::text       AS tabla_referenciada,
        pg_get_constraintdef(k.oid)       AS definicion
FROM    pg_constraint k
JOIN    pg_class c     ON c.oid = k.conrelid
JOIN    pg_namespace n ON n.oid = c.relnamespace
WHERE   k.contype IN ('p', 'f', 'u')
  AND   n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
COMMENT ON VIEW auditoria.v_dic_llaves IS 'Diccionario: llaves primarias, foráneas y únicas';

-- ---------------------------------------------------------------------
-- Triggers existentes (permite verificar los generados por AutoAudit)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_dic_triggers AS
SELECT  n.nspname                    AS esquema,
        c.relname                    AS tabla,
        t.tgname                     AS trigger_nombre,
        p.proname                    AS funcion,
        CASE t.tgenabled WHEN 'D' THEN false ELSE true END AS habilitado,
        (t.tgname = 'trg_autoaudit') AS es_autoaudit,
        pg_get_triggerdef(t.oid)     AS definicion
FROM    pg_trigger t
JOIN    pg_class c     ON c.oid = t.tgrelid
JOIN    pg_namespace n ON n.oid = c.relnamespace
JOIN    pg_proc p      ON p.oid = t.tgfoid
WHERE   NOT t.tgisinternal;
COMMENT ON VIEW auditoria.v_dic_triggers IS 'Diccionario: triggers definidos por usuarios';

-- ---------------------------------------------------------------------
-- Funciones de apoyo para validar existencia (usadas por la configuración)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_dic_oid_tabla(p_esquema text, p_tabla text)
RETURNS oid LANGUAGE sql STABLE AS $$
    SELECT c.oid
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_esquema AND c.relname = p_tabla AND c.relkind IN ('r','p');
$$;

CREATE OR REPLACE FUNCTION auditoria.fn_dic_llave_primaria(p_oid oid)
RETURNS name[] LANGUAGE sql STABLE AS $$
    SELECT array_agg(a.attname ORDER BY x.ord)
      FROM pg_constraint k
      CROSS JOIN LATERAL unnest(k.conkey) WITH ORDINALITY x(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.attnum
     WHERE k.conrelid = p_oid AND k.contype = 'p';
$$;
