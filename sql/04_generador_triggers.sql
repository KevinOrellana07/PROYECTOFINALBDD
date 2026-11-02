-- =====================================================================
-- AutoAudit - 04_generador_triggers.sql
-- Módulo de generación dinámica de triggers + funciones de registro.
--
-- Por cada tabla configurada se genera:
--   * Una función PL/pgSQL EXCLUSIVA de esa tabla:
--       auditoria.fn_aud_<id>_<esquema>_<tabla>()
--     con las columnas y eventos "compilados" en el código (sin consultar
--     la configuración en cada fila => mínimo impacto en rendimiento).
--   * Un trigger AFTER ... FOR EACH ROW llamado trg_autoaudit en la tabla
--     origen, que solo se dispara en los eventos configurados
--     (UPDATE OF <columnas> para no disparar con columnas no auditadas).
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- IP de origen respetando la política de privacidad (parámetro ip_modo)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_ip_cliente()
RETURNS text LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_modo text;
    v_ip   inet := inet_client_addr();
BEGIN
    SELECT valor INTO v_modo FROM auditoria.parametro WHERE clave = 'ip_modo';
    IF v_ip IS NULL THEN
        RETURN 'local';                         -- conexión por socket Unix
    ELSIF v_modo = 'ninguna' THEN
        RETURN 'no registrada';
    ELSIF v_modo = 'anonimizada' THEN           -- IPv4 /24, IPv6 /48
        RETURN host(network(set_masklen(v_ip, CASE family(v_ip) WHEN 4 THEN 24 ELSE 48 END)))
               || ' (anon)';
    END IF;
    RETURN host(v_ip);
END;
$$;

-- ---------------------------------------------------------------------
-- Crea el encabezado de bitácora con el contexto de la sesión.
-- Solo autoaudit_owner (dueño de las funciones de trigger) puede ejecutarla.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_crear_encabezado(
    p_tabla_id integer, p_evento_id smallint,
    p_anterior jsonb, p_nuevo jsonb, p_llave jsonb)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_usuario  name := session_user;
    v_ip       text := auditoria.fn_ip_cliente();
    v_equipo   text := left(COALESCE(NULLIF(current_setting('autoaudit.equipo', true), ''), 'desconocido'), 128);
    v_app      text := left(COALESCE(NULLIF(current_setting('application_name', true), ''), 'desconocida'), 128);
    v_usr_app  text := left(NULLIF(current_setting('autoaudit.usuario_app', true), ''), 128);
    v_uid      integer;
    v_eid      integer;
    v_id       bigint;
BEGIN
    -- Usuario
    SELECT usuario_id INTO v_uid FROM usuario_auditado WHERE nombre_usuario = v_usuario;
    IF v_uid IS NULL THEN
        INSERT INTO usuario_auditado (nombre_usuario) VALUES (v_usuario)
        ON CONFLICT (nombre_usuario) DO NOTHING RETURNING usuario_id INTO v_uid;
        IF v_uid IS NULL THEN
            SELECT usuario_id INTO v_uid FROM usuario_auditado WHERE nombre_usuario = v_usuario;
        END IF;
    END IF;

    -- Estación de trabajo
    SELECT estacion_id INTO v_eid FROM estacion_trabajo
     WHERE direccion_ip = v_ip AND equipo = v_equipo AND aplicacion = v_app;
    IF v_eid IS NULL THEN
        INSERT INTO estacion_trabajo (direccion_ip, equipo, aplicacion) VALUES (v_ip, v_equipo, v_app)
        ON CONFLICT (direccion_ip, equipo, aplicacion) DO NOTHING RETURNING estacion_id INTO v_eid;
        IF v_eid IS NULL THEN
            SELECT estacion_id INTO v_eid FROM estacion_trabajo
             WHERE direccion_ip = v_ip AND equipo = v_equipo AND aplicacion = v_app;
        END IF;
    END IF;

    INSERT INTO bitacora_encabezado
           (tabla_id, evento_id, usuario_id, estacion_id, usuario_aplicacion,
            llave_registro, datos_anteriores, datos_nuevos)
    VALUES (p_tabla_id, p_evento_id, v_uid, v_eid, v_usr_app,
            p_llave, p_anterior, p_nuevo)
    RETURNING encabezado_id INTO v_id;
    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Construye (sin ejecutar) el código SQL del trigger de una tabla.
-- Útil como "vista previa" desde la interfaz.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_construir_sql_trigger(p_tabla_id integer)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    r_t        tabla_auditada%ROWTYPE;
    v_funcion  text;
    v_pk       name[];
    v_pk_new   text;
    v_pk_old   text;
    v_sql      text;
    v_ins      text;
    v_upd      text;
    v_del      text;
    v_eventos  text[] := '{}';
    v_cols_upd text;
    v_resumen  text;
    v_cab      text := 'INSERT INTO auditoria.bitacora_detalle '
                       '(encabezado_id, configuracion_id, columna_id, valor_anterior, valor_nuevo)';
BEGIN
    SELECT * INTO r_t FROM tabla_auditada WHERE tabla_id = p_tabla_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la configuración %', p_tabla_id;
    END IF;

    v_funcion := COALESCE(r_t.funcion_trigger,
                 left('fn_aud_' || p_tabla_id || '_' ||
                      regexp_replace(lower(r_t.esquema || '_' || r_t.tabla), '[^a-z0-9_]', '_', 'g'), 63));

    -- Llave primaria => expresión jsonb para identificar el registro
    v_pk := auditoria.fn_dic_llave_primaria(r_t.tabla_oid);
    IF v_pk IS NULL THEN
        v_pk_new := 'NULL'; v_pk_old := 'NULL';
    ELSE
        SELECT 'jsonb_build_object(' || string_agg(format('%L, NEW.%I', c, c), ', ') || ')',
               'jsonb_build_object(' || string_agg(format('%L, OLD.%I', c, c), ', ') || ')'
          INTO v_pk_new, v_pk_old
          FROM unnest(v_pk) AS c;
    END IF;

    -- ---------------- INSERT: se registran todas las columnas configuradas
    SELECT string_agg(format('(v_enc, %s, %s, NULL, NEW.%I::text)',
                             cf.configuracion_id, ca.columna_id, ca.columna),
                      E',\n               ' ORDER BY ca.attnum)
      INTO v_ins
      FROM columna_auditada ca JOIN configuracion_auditoria cf USING (columna_id)
     WHERE ca.tabla_id = p_tabla_id AND ca.activa AND NOT ca.eliminada
       AND cf.activo AND cf.evento_id = 1;

    -- ---------------- UPDATE: solo columnas cuyo valor cambió
    SELECT string_agg(format(
$f$        IF OLD.%1$I IS DISTINCT FROM NEW.%1$I THEN
            v_enc := COALESCE(v_enc, auditoria.fn_crear_encabezado(%2$s, 2::smallint, to_jsonb(OLD), to_jsonb(NEW), %3$s));
            %4$s
            VALUES (v_enc, %5$s, %6$s, OLD.%1$I::text, NEW.%1$I::text);
        END IF;$f$,
                ca.columna, p_tabla_id, v_pk_new, v_cab, cf.configuracion_id, ca.columna_id),
                E'\n' ORDER BY ca.attnum),
           string_agg(quote_ident(ca.columna), ', ' ORDER BY ca.attnum)
      INTO v_upd, v_cols_upd
      FROM columna_auditada ca JOIN configuracion_auditoria cf USING (columna_id)
     WHERE ca.tabla_id = p_tabla_id AND ca.activa AND NOT ca.eliminada
       AND cf.activo AND cf.evento_id = 2;

    -- ---------------- DELETE: se preservan los valores anteriores
    SELECT string_agg(format('(v_enc, %s, %s, OLD.%I::text, NULL)',
                             cf.configuracion_id, ca.columna_id, ca.columna),
                      E',\n               ' ORDER BY ca.attnum)
      INTO v_del
      FROM columna_auditada ca JOIN configuracion_auditoria cf USING (columna_id)
     WHERE ca.tabla_id = p_tabla_id AND ca.activa AND NOT ca.eliminada
       AND cf.activo AND cf.evento_id = 3;

    IF v_ins IS NULL AND v_upd IS NULL AND v_del IS NULL THEN
        RAISE EXCEPTION 'La tabla %.% no tiene columnas con eventos activos', r_t.esquema, r_t.tabla;
    END IF;

    v_sql := format(
$h$-- =====================================================================
-- Código generado automáticamente por AutoAudit. NO EDITAR A MANO.
-- Tabla origen : %1$I.%2$I   (tabla_id = %3$s)
-- Generado     : %4$s por %5$s
-- =====================================================================
CREATE OR REPLACE FUNCTION auditoria.%6$I()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $autoaudit$
DECLARE
    v_enc bigint;
BEGIN
$h$,
        r_t.esquema, r_t.tabla, p_tabla_id,
        to_char(now(), 'YYYY-MM-DD HH24:MI:SS'), session_user, v_funcion);

    IF v_ins IS NOT NULL THEN
        v_eventos := v_eventos || 'INSERT'::text;
        v_sql := v_sql || format(
$i$    IF TG_OP = 'INSERT' THEN
        v_enc := auditoria.fn_crear_encabezado(%s, 1::smallint, NULL, to_jsonb(NEW), %s);
        %s
        VALUES %s;
        RETURN NULL;
    END IF;
$i$, p_tabla_id, v_pk_new, v_cab, v_ins);
    END IF;

    IF v_upd IS NOT NULL THEN
        v_eventos := v_eventos || format('UPDATE OF %s', v_cols_upd);
        v_sql := v_sql || E'    IF TG_OP = ''UPDATE'' THEN\n' || v_upd || E'\n        RETURN NULL;\n    END IF;\n';
    END IF;

    IF v_del IS NOT NULL THEN
        v_eventos := v_eventos || 'DELETE'::text;
        v_sql := v_sql || format(
$d$    IF TG_OP = 'DELETE' THEN
        v_enc := auditoria.fn_crear_encabezado(%s, 3::smallint, to_jsonb(OLD), NULL, %s);
        %s
        VALUES %s;
        RETURN NULL;
    END IF;
$d$, p_tabla_id, v_pk_old, v_cab, v_del);
    END IF;

    v_sql := v_sql || format(
$e$    RETURN NULL;
END;
$autoaudit$;

ALTER FUNCTION auditoria.%1$I() OWNER TO autoaudit_owner;
REVOKE ALL ON FUNCTION auditoria.%1$I() FROM PUBLIC;
COMMENT ON FUNCTION auditoria.%1$I() IS 'AutoAudit: trigger de auditoría de %2$I.%3$I';

CREATE OR REPLACE TRIGGER trg_autoaudit
    AFTER %4$s
    ON %2$I.%3$I
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.%1$I();
$e$, v_funcion, r_t.esquema, r_t.tabla, array_to_string(v_eventos, ' OR '));

    RETURN v_sql;
END;
$$;

-- ---------------------------------------------------------------------
-- Genera y aplica el trigger de una tabla (con manejo de errores).
-- Retorna jsonb: {exito, mensaje, sql, avisos}
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_generar_trigger_interno(p_tabla_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_sql     text;
    v_funcion text;
    v_errores text;
    v_avisos  text;
    v_msg     text;
    v_det     text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tabla_auditada WHERE tabla_id = p_tabla_id) THEN
        RAISE EXCEPTION 'No existe la configuración %', p_tabla_id;
    END IF;

    -- 1) Sincronizar nombres y validar contra el diccionario
    PERFORM auditoria.fn_sincronizar_tabla(p_tabla_id);
    SELECT string_agg(mensaje, '; ') FILTER (WHERE nivel = 'ERROR'),
           string_agg(mensaje, '; ') FILTER (WHERE nivel = 'AVISO')
      INTO v_errores, v_avisos
      FROM auditoria.fn_validar_configuracion(p_tabla_id);

    IF v_errores IS NOT NULL THEN
        -- Un trigger desactualizado podría romper las operaciones de los usuarios
        -- (p.ej. columna eliminada): se retira y la tabla queda en ERROR.
        PERFORM auditoria.fn_eliminar_trigger_interno(p_tabla_id);
        UPDATE tabla_auditada SET estado = 'ERROR', ultimo_error = v_errores
         WHERE tabla_id = p_tabla_id AND estado <> 'HUERFANA';
        INSERT INTO log_generacion (tabla_id, accion, exito, mensaje)
        VALUES (p_tabla_id, 'VALIDAR', false, v_errores);
        RETURN jsonb_build_object('exito', false, 'mensaje', v_errores, 'avisos', v_avisos);
    END IF;

    IF NOT (SELECT activa FROM tabla_auditada WHERE tabla_id = p_tabla_id) THEN
        RETURN jsonb_build_object('exito', false,
               'mensaje', 'La tabla está desactivada; actívela para generar el trigger');
    END IF;

    -- 2) Construir y ejecutar (en un sub-bloque: si falla se revierte solo esto)
    BEGIN
        v_sql := auditoria.fn_construir_sql_trigger(p_tabla_id);
        v_funcion := substring(v_sql FROM 'CREATE OR REPLACE FUNCTION auditoria\.("?[a-z0-9_]+"?)\(\)');
        EXECUTE v_sql;

        UPDATE tabla_auditada
           SET estado = 'ACTIVO', funcion_trigger = trim(both '"' from v_funcion),
               trigger_nombre = 'trg_autoaudit', sql_generado = v_sql,
               fecha_generacion = now(), ultimo_error = NULL
         WHERE tabla_id = p_tabla_id;

        INSERT INTO log_generacion (tabla_id, objeto, accion, exito, mensaje, sql_ejecutado)
        VALUES (p_tabla_id, v_funcion, 'GENERAR', true, COALESCE('Avisos: ' || v_avisos, 'OK'), v_sql);

        RETURN jsonb_build_object('exito', true, 'mensaje', 'Trigger generado correctamente',
                                  'avisos', v_avisos, 'sql', v_sql);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
        UPDATE tabla_auditada SET estado = 'ERROR', ultimo_error = v_msg WHERE tabla_id = p_tabla_id;
        INSERT INTO log_generacion (tabla_id, accion, exito, mensaje, sql_ejecutado)
        VALUES (p_tabla_id, 'GENERAR', false, v_msg || COALESCE(' / ' || v_det, ''), v_sql);
        RETURN jsonb_build_object('exito', false, 'mensaje', v_msg, 'sql', v_sql);
    END;
END;
$$;

-- Punto de entrada público (valida privilegios de administrador)
CREATE OR REPLACE FUNCTION auditoria.fn_generar_trigger(p_tabla_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    RETURN auditoria.fn_generar_trigger_interno(p_tabla_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Elimina el trigger y la función generada de una tabla
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_eliminar_trigger_interno(p_tabla_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    r_t   tabla_auditada%ROWTYPE;
    v_sql text := '';
BEGIN
    SELECT * INTO r_t FROM tabla_auditada WHERE tabla_id = p_tabla_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la configuración %', p_tabla_id;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_class WHERE oid = r_t.tabla_oid) THEN
        v_sql := format('DROP TRIGGER IF EXISTS trg_autoaudit ON %s;', r_t.tabla_oid::regclass);
    END IF;
    IF r_t.funcion_trigger IS NOT NULL THEN
        v_sql := v_sql || format(' DROP FUNCTION IF EXISTS auditoria.%I();', r_t.funcion_trigger);
    END IF;
    IF v_sql <> '' THEN
        EXECUTE v_sql;
    END IF;

    UPDATE tabla_auditada
       SET estado = CASE WHEN estado = 'HUERFANA' THEN 'HUERFANA' ELSE 'INACTIVO' END
     WHERE tabla_id = p_tabla_id;

    IF v_sql <> '' THEN
        INSERT INTO log_generacion (tabla_id, objeto, accion, exito, mensaje, sql_ejecutado)
        VALUES (p_tabla_id, r_t.funcion_trigger, 'ELIMINAR', true, 'Trigger eliminado', v_sql);
    END IF;

    RETURN jsonb_build_object('exito', true, 'mensaje', 'Trigger eliminado', 'sql', v_sql);
END;
$$;

CREATE OR REPLACE FUNCTION auditoria.fn_eliminar_trigger(p_tabla_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    RETURN auditoria.fn_eliminar_trigger_interno(p_tabla_id);
END;
$$;

-- ---------------------------------------------------------------------
-- Regenera los triggers de todas las tablas activas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_regenerar_todos()
RETURNS TABLE (tabla_id integer, tabla text, exito boolean, mensaje text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    r record;
    v_res jsonb;
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    FOR r IN SELECT t.tabla_id, t.esquema || '.' || t.tabla AS nombre
               FROM tabla_auditada t WHERE t.activa AND t.estado <> 'HUERFANA'
              ORDER BY t.tabla_id
    LOOP
        v_res := auditoria.fn_generar_trigger(r.tabla_id);
        tabla_id := r.tabla_id; tabla := r.nombre;
        exito := (v_res->>'exito')::boolean; mensaje := v_res->>'mensaje';
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Estado de la auditoría: compara configuración vs triggers reales
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW auditoria.v_estado_auditoria AS
SELECT  t.tabla_id,
        t.esquema, t.tabla, t.descripcion, t.activa, t.estado,
        t.funcion_trigger, t.fecha_generacion, t.ultimo_error,
        (SELECT count(*) FROM auditoria.columna_auditada c
          WHERE c.tabla_id = t.tabla_id AND c.activa AND NOT c.eliminada) AS columnas_activas,
        (SELECT string_agg(DISTINCT e.codigo, ', ' ORDER BY e.codigo)
           FROM auditoria.columna_auditada c
           JOIN auditoria.configuracion_auditoria cf USING (columna_id)
           JOIN auditoria.evento e USING (evento_id)
          WHERE c.tabla_id = t.tabla_id AND c.activa AND NOT c.eliminada AND cf.activo) AS eventos,
        EXISTS (SELECT 1 FROM pg_trigger tg
                 WHERE tg.tgrelid = t.tabla_oid AND tg.tgname = 'trg_autoaudit') AS trigger_existe,
        (t.activa AND t.estado = 'ACTIVO') =
        EXISTS (SELECT 1 FROM pg_trigger tg
                 WHERE tg.tgrelid = t.tabla_oid AND tg.tgname = 'trg_autoaudit') AS sincronizado,
        (SELECT count(*) FROM auditoria.bitacora_encabezado b WHERE b.tabla_id = t.tabla_id) AS registros_bitacora
FROM    auditoria.tabla_auditada t;
COMMENT ON VIEW auditoria.v_estado_auditoria IS 'Estado actual de la auditoría por tabla';
