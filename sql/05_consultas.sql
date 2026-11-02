-- =====================================================================
-- AutoAudit - 05_consultas.sql : Consultas parametrizadas de historial
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Vista plana de la bitácora (un renglón por columna afectada)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_bitacora AS
SELECT  e.encabezado_id,
        d.detalle_id,
        e.fecha_hora,
        ev.codigo                AS operacion,
        t.esquema,
        t.tabla,
        c.columna,
        d.valor_anterior,
        d.valor_nuevo,
        e.llave_registro,
        u.nombre_usuario         AS usuario,
        e.usuario_aplicacion,
        s.direccion_ip,
        s.equipo,
        s.aplicacion,
        e.transaccion_id,
        d.configuracion_id,
        e.tabla_id,
        d.columna_id,
        e.usuario_id,
        e.estacion_id
FROM    auditoria.bitacora_encabezado e
JOIN    auditoria.bitacora_detalle   d  ON d.encabezado_id = e.encabezado_id
JOIN    auditoria.evento             ev ON ev.evento_id    = e.evento_id
JOIN    auditoria.tabla_auditada     t  ON t.tabla_id      = e.tabla_id
JOIN    auditoria.columna_auditada   c  ON c.columna_id    = d.columna_id
JOIN    auditoria.usuario_auditado   u  ON u.usuario_id    = e.usuario_id
JOIN    auditoria.estacion_trabajo   s  ON s.estacion_id   = e.estacion_id;
COMMENT ON VIEW auditoria.v_bitacora IS 'Bitácora desnormalizada para consulta y reportes';

-- ---------------------------------------------------------------------
-- Historial general con filtros opcionales (NULL = sin filtro)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_consultar_bitacora(
    p_usuario    text        DEFAULT NULL,
    p_esquema    text        DEFAULT NULL,
    p_tabla      text        DEFAULT NULL,
    p_columna    text        DEFAULT NULL,
    p_operacion  text        DEFAULT NULL,
    p_desde      timestamptz DEFAULT NULL,
    p_hasta      timestamptz DEFAULT NULL,
    p_limite     integer     DEFAULT 1000)
RETURNS SETOF auditoria.v_bitacora
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_where text[] := '{}';
    v_usr   integer;
    v_tabs  integer[];
    v_cols  integer[];
BEGIN
    -- Los filtros por nombre se traducen a identificadores para usar los índices,
    -- y solo se incluyen en la consulta los filtros que fueron indicados.
    IF p_usuario IS NOT NULL THEN
        SELECT usuario_id INTO v_usr FROM usuario_auditado WHERE nombre_usuario = p_usuario;
        v_where := v_where || 'b.usuario_id = $1'::text;
    END IF;
    IF p_esquema IS NOT NULL OR p_tabla IS NOT NULL THEN
        SELECT array_agg(tabla_id) INTO v_tabs FROM tabla_auditada
         WHERE (p_esquema IS NULL OR esquema = p_esquema) AND (p_tabla IS NULL OR tabla = p_tabla);
        v_where := v_where || 'b.tabla_id = ANY ($2)'::text;
    END IF;
    IF p_columna IS NOT NULL THEN
        SELECT array_agg(c.columna_id) INTO v_cols
          FROM columna_auditada c JOIN tabla_auditada t USING (tabla_id)
         WHERE c.columna = p_columna
           AND (p_esquema IS NULL OR t.esquema = p_esquema) AND (p_tabla IS NULL OR t.tabla = p_tabla);
        v_where := v_where || 'b.columna_id = ANY ($3)'::text;
    END IF;
    IF p_operacion IS NOT NULL THEN
        v_where := v_where || 'b.operacion = upper($4)'::text;
    END IF;
    IF p_desde IS NOT NULL THEN v_where := v_where || 'b.fecha_hora >= $5'::text; END IF;
    IF p_hasta IS NOT NULL THEN v_where := v_where || 'b.fecha_hora <  $6'::text; END IF;

    RETURN QUERY EXECUTE
        'SELECT * FROM auditoria.v_bitacora b'
        || CASE WHEN cardinality(v_where) > 0 THEN ' WHERE ' || array_to_string(v_where, ' AND ') ELSE '' END
        || ' ORDER BY b.fecha_hora DESC, b.detalle_id DESC LIMIT $7'
    USING v_usr, COALESCE(v_tabs, '{}'), COALESCE(v_cols, '{}'), p_operacion, p_desde, p_hasta,
          COALESCE(p_limite, 1000);
END;
$$;

-- ---------------------------------------------------------------------
-- Historial completo de modificaciones de un USUARIO
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_historial_usuario(
    p_usuario text,
    p_desde   timestamptz DEFAULT NULL,
    p_hasta   timestamptz DEFAULT NULL)
RETURNS SETOF auditoria.v_bitacora
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT usuario_id INTO v_id FROM auditoria.usuario_auditado WHERE nombre_usuario = p_usuario;
    RETURN QUERY EXECUTE
        'SELECT * FROM auditoria.v_bitacora b
          WHERE b.usuario_id = $1
            AND ($2 IS NULL OR b.fecha_hora >= $2)
            AND ($3 IS NULL OR b.fecha_hora <  $3)
          ORDER BY b.fecha_hora, b.detalle_id'
    USING v_id, p_desde, p_hasta;
END;
$$;

-- ---------------------------------------------------------------------
-- Todos los cambios realizados en una COLUMNA específica
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_historial_columna(
    p_esquema text, p_tabla text, p_columna text,
    p_desde   timestamptz DEFAULT NULL,
    p_hasta   timestamptz DEFAULT NULL)
RETURNS SETOF auditoria.v_bitacora
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_ids integer[];
BEGIN
    -- Se resuelven primero los id de columna para aprovechar el índice ix_det_columna
    SELECT array_agg(c.columna_id) INTO v_ids
      FROM auditoria.columna_auditada c
      JOIN auditoria.tabla_auditada t USING (tabla_id)
     WHERE t.esquema = p_esquema AND t.tabla = p_tabla AND c.columna = p_columna;

    RETURN QUERY EXECUTE
        'SELECT * FROM auditoria.v_bitacora b
          WHERE b.columna_id = ANY ($1)
            AND ($2 IS NULL OR b.fecha_hora >= $2)
            AND ($3 IS NULL OR b.fecha_hora <  $3)
          ORDER BY b.fecha_hora, b.detalle_id'
    USING COALESCE(v_ids, '{}'), p_desde, p_hasta;
END;
$$;

-- ---------------------------------------------------------------------
-- Línea de tiempo de UN registro (por su llave primaria en jsonb)
--   SELECT * FROM auditoria.fn_historial_registro('tienda','clientes','{"cliente_id":1}');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_historial_registro(
    p_esquema text, p_tabla text, p_llave jsonb)
RETURNS SETOF auditoria.v_bitacora
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_encs bigint[];
BEGIN
    -- 1) operaciones del registro (índice GIN sobre llave_registro)
    SELECT array_agg(e.encabezado_id) INTO v_encs
      FROM bitacora_encabezado e
     WHERE e.llave_registro @> p_llave
       AND e.tabla_id IN (SELECT tabla_id FROM tabla_auditada
                           WHERE esquema = p_esquema AND tabla = p_tabla);
    -- 2) detalle de esas operaciones
    RETURN QUERY EXECUTE
        'SELECT * FROM auditoria.v_bitacora b WHERE b.encabezado_id = ANY ($1)
          ORDER BY b.fecha_hora, b.detalle_id'
    USING COALESCE(v_encs, '{}');
END;
$$;

-- ---------------------------------------------------------------------
-- Registros eliminados (con la fila completa preservada)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_registros_eliminados AS
SELECT  e.encabezado_id, e.fecha_hora, t.esquema, t.tabla,
        e.llave_registro, e.datos_anteriores AS registro_eliminado,
        u.nombre_usuario AS usuario, s.direccion_ip, s.equipo
FROM    auditoria.bitacora_encabezado e
JOIN    auditoria.tabla_auditada   t ON t.tabla_id   = e.tabla_id
JOIN    auditoria.usuario_auditado u ON u.usuario_id = e.usuario_id
JOIN    auditoria.estacion_trabajo s ON s.estacion_id = e.estacion_id
WHERE   e.evento_id = 3;

-- ---------------------------------------------------------------------
-- Resumen de actividad por usuario
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_resumen_usuarios AS
SELECT  u.usuario_id, u.nombre_usuario AS usuario,
        count(*)                                     AS operaciones,
        count(*) FILTER (WHERE e.evento_id = 1)      AS inserciones,
        count(*) FILTER (WHERE e.evento_id = 2)      AS actualizaciones,
        count(*) FILTER (WHERE e.evento_id = 3)      AS eliminaciones,
        min(e.fecha_hora)                            AS primera_actividad,
        max(e.fecha_hora)                            AS ultima_actividad
FROM    auditoria.usuario_auditado u
JOIN    auditoria.bitacora_encabezado e ON e.usuario_id = u.usuario_id
GROUP BY u.usuario_id, u.nombre_usuario;

-- ---------------------------------------------------------------------
-- Estadísticas para el panel principal
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_estadisticas(p_dias integer DEFAULT 14)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, auditoria
AS $$
    SELECT jsonb_build_object(
        'tablas_auditadas', (SELECT count(*) FROM tabla_auditada WHERE activa AND estado = 'ACTIVO'),
        'tablas_config',    (SELECT count(*) FROM tabla_auditada),
        'columnas',         (SELECT count(*) FROM columna_auditada WHERE activa AND NOT eliminada),
        'operaciones',      (SELECT count(*) FROM bitacora_encabezado),
        'cambios',          (SELECT count(*) FROM bitacora_detalle),
        'usuarios',         (SELECT count(*) FROM usuario_auditado),
        'estaciones',       (SELECT count(*) FROM estacion_trabajo),
        'hoy',              (SELECT count(*) FROM bitacora_encabezado WHERE fecha_hora >= current_date),
        'por_dia', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('dia', d::date, 'ins', i, 'upd', u, 'del', x) ORDER BY d)
              FROM (SELECT g.d,
                           count(e.*) FILTER (WHERE e.evento_id = 1) i,
                           count(e.*) FILTER (WHERE e.evento_id = 2) u,
                           count(e.*) FILTER (WHERE e.evento_id = 3) x
                      FROM generate_series(current_date - (p_dias - 1), current_date, interval '1 day') g(d)
                      LEFT JOIN bitacora_encabezado e
                             ON e.fecha_hora >= g.d AND e.fecha_hora < g.d + interval '1 day'
                     GROUP BY g.d) s), '[]'::jsonb),
        'por_tabla', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('tabla', t.esquema || '.' || t.tabla, 'n', n) ORDER BY n DESC)
              FROM (SELECT tabla_id, count(*) n FROM bitacora_encabezado GROUP BY tabla_id) x
              JOIN tabla_auditada t USING (tabla_id)), '[]'::jsonb),
        'por_usuario', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('usuario', usuario, 'n', operaciones) ORDER BY operaciones DESC)
              FROM v_resumen_usuarios), '[]'::jsonb)
    );
$$;

-- ---------------------------------------------------------------------
-- Depuración por política de retención (solo superusuario)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_purgar_bitacora()
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_dias integer;
    v_n    bigint;
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'Solo un superusuario puede depurar la bitácora';
    END IF;
    SELECT valor::integer INTO v_dias FROM parametro WHERE clave = 'dias_retencion';
    PERFORM set_config('autoaudit.mantenimiento', 'on', true);
    DELETE FROM bitacora_detalle d USING bitacora_encabezado e
     WHERE d.encabezado_id = e.encabezado_id AND e.fecha_hora < now() - make_interval(days => v_dias);
    DELETE FROM bitacora_encabezado WHERE fecha_hora < now() - make_interval(days => v_dias);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO log_generacion (accion, exito, mensaje)
    VALUES ('PURGAR', true, format('%s operaciones con más de %s días eliminadas', v_n, v_dias));
    RETURN v_n;
END;
$$;
