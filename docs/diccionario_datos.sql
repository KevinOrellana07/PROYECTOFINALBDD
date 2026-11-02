-- =====================================================================
-- AutoAudit - Genera el diccionario de datos del esquema "auditoria"
-- directamente desde el catálogo de PostgreSQL.
--   psql -h 127.0.0.1 -U auditor -d autoaudit_db -f docs/diccionario_datos.sql
-- =====================================================================
\pset border 2
\pset footer off

\echo '=== TABLAS DEL SISTEMA DE AUDITORÍA ==='
SELECT c.relname AS tabla, obj_description(c.oid, 'pg_class') AS descripcion
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'auditoria' AND c.relkind = 'r'
 ORDER BY c.relname;

\echo '=== COLUMNAS ==='
SELECT c.relname                                    AS tabla,
       a.attname                                    AS columna,
       format_type(a.atttypid, a.atttypmod)         AS tipo,
       CASE WHEN a.attnotnull THEN 'NO' ELSE 'SÍ' END AS nulo,
       concat_ws(' ',
         CASE WHEN a.attnum = ANY (pk.conkey) THEN 'PK' END,
         (SELECT string_agg('FK→' || fk.confrelid::regclass::text, ' ')
            FROM pg_constraint fk WHERE fk.conrelid = c.oid AND fk.contype = 'f' AND a.attnum = ANY (fk.conkey)),
         CASE WHEN EXISTS (SELECT 1 FROM pg_constraint u WHERE u.conrelid = c.oid AND u.contype = 'u'
                            AND a.attnum = ANY (u.conkey)) THEN 'UQ' END) AS llave,
       pg_get_expr(d.adbin, d.adrelid)              AS defecto,
       col_description(c.oid, a.attnum)             AS descripcion
  FROM pg_attribute a
  JOIN pg_class c      ON c.oid = a.attrelid
  JOIN pg_namespace n  ON n.oid = c.relnamespace
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  LEFT JOIN pg_constraint pk ON pk.conrelid = c.oid AND pk.contype = 'p'
 WHERE n.nspname = 'auditoria' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY c.relname, a.attnum;

\echo '=== RESTRICCIONES ==='
SELECT tabla, restriccion, tipo, definicion
  FROM auditoria.v_dic_llaves WHERE esquema = 'auditoria' ORDER BY tabla, tipo;

\echo '=== ÍNDICES ==='
SELECT tablename AS tabla, indexname AS indice, indexdef AS definicion
  FROM pg_indexes WHERE schemaname = 'auditoria' ORDER BY tablename, indexname;

\echo '=== FUNCIONES ==='
SELECT p.proname AS funcion, pg_get_function_identity_arguments(p.oid) AS parametros,
       pg_get_function_result(p.oid) AS retorna,
       CASE WHEN p.prosecdef THEN 'DEFINER' ELSE 'INVOKER' END AS seguridad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'auditoria' ORDER BY p.proname;
