-- =====================================================================
-- AutoAudit - 03_funciones_config.sql : Módulo de configuración
-- Todas las funciones validan contra el diccionario de datos antes de
-- guardar, y solo pueden ejecutarlas miembros de autoaudit_admin.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Seguridad: solo administradores de auditoría (o superusuarios)
-- Se usa session_user porque dentro de SECURITY DEFINER current_user
-- es el dueño de la función.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_es_admin()
RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT pg_has_role(session_user, 'autoaudit_admin', 'MEMBER')
        OR COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), false);
$$;

CREATE OR REPLACE FUNCTION auditoria.fn_verificar_admin()
RETURNS void LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    IF NOT auditoria.fn_es_admin() THEN
        RAISE EXCEPTION 'El usuario "%" no tiene privilegios para configurar la auditoría', session_user
            USING ERRCODE = '42501',
                  HINT = 'Se requiere pertenecer al rol autoaudit_admin';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Registrar (habilitar) una tabla para auditoría
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_registrar_tabla(
    p_esquema text, p_tabla text, p_descripcion text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_oid oid;
    v_id  integer;
BEGIN
    PERFORM auditoria.fn_verificar_admin();

    v_oid := auditoria.fn_dic_oid_tabla(p_esquema, p_tabla);
    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'La tabla %.% no existe en el diccionario de datos', p_esquema, p_tabla
            USING ERRCODE = '42P01';
    END IF;
    IF p_esquema = 'auditoria' THEN
        RAISE EXCEPTION 'No se pueden auditar las tablas del propio sistema de auditoría';
    END IF;

    -- Una configuración previa con el mismo nombre cuya tabla ya no existe
    -- (eliminada y recreada) se marca como HUERFANA y conserva su historial.
    UPDATE tabla_auditada t
       SET estado = 'HUERFANA', activa = false, ultimo_error = 'La tabla origen fue eliminada'
     WHERE t.esquema = p_esquema AND t.tabla = p_tabla AND t.estado <> 'HUERFANA'
       AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.tabla_oid);

    SELECT tabla_id INTO v_id FROM tabla_auditada WHERE tabla_oid = v_oid;
    IF v_id IS NULL THEN
        INSERT INTO tabla_auditada (tabla_oid, esquema, tabla, descripcion)
        VALUES (v_oid, p_esquema, p_tabla, p_descripcion)
        RETURNING tabla_id INTO v_id;
    ELSIF p_descripcion IS NOT NULL THEN
        UPDATE tabla_auditada
           SET descripcion = p_descripcion, modificado_por = session_user, fecha_modificacion = now()
         WHERE tabla_id = v_id;
    END IF;

    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Configurar una columna y los eventos que se auditan sobre ella
--   Si los tres eventos quedan en false, la columna se desactiva.
--   NO genera el trigger: para aplicar use fn_generar_trigger().
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_configurar_columna(
    p_esquema text, p_tabla text, p_columna text,
    p_insert boolean DEFAULT true,
    p_update boolean DEFAULT true,
    p_delete boolean DEFAULT true)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_tabla_id integer;
    v_oid      oid;
    v_attnum   smallint;
    v_tipo     text;
    v_col_id   integer;
    v_activa   boolean := (p_insert OR p_update OR p_delete);
BEGIN
    PERFORM auditoria.fn_verificar_admin();

    -- 1) La tabla debe existir (se registra si aún no lo está)
    v_tabla_id := auditoria.fn_registrar_tabla(p_esquema, p_tabla);
    SELECT tabla_oid INTO v_oid FROM tabla_auditada WHERE tabla_id = v_tabla_id;

    -- 2) La columna debe existir en el diccionario
    SELECT a.attnum, format_type(a.atttypid, a.atttypmod)
      INTO v_attnum, v_tipo
      FROM pg_attribute a
     WHERE a.attrelid = v_oid AND a.attname = p_columna
       AND a.attnum > 0 AND NOT a.attisdropped;
    IF v_attnum IS NULL THEN
        RAISE EXCEPTION 'La columna "%" no existe en %.%', p_columna, p_esquema, p_tabla
            USING ERRCODE = '42703';
    END IF;

    -- 3) Guardar columna
    INSERT INTO columna_auditada (tabla_id, columna, attnum, tipo_dato, activa)
    VALUES (v_tabla_id, p_columna, v_attnum, v_tipo, v_activa)
    ON CONFLICT (tabla_id, attnum) DO UPDATE
        SET columna = EXCLUDED.columna,
            tipo_dato = EXCLUDED.tipo_dato,
            activa = EXCLUDED.activa,
            eliminada = false
    RETURNING columna_id INTO v_col_id;

    -- 4) Guardar configuración por evento (columna x evento)
    UPDATE configuracion_auditoria cf
       SET activo = v.activo, fecha_modificacion = now()
      FROM (VALUES (1::smallint, p_insert), (2::smallint, p_update), (3::smallint, p_delete)) v(evento_id, activo)
     WHERE cf.columna_id = v_col_id AND cf.evento_id = v.evento_id
       AND cf.activo IS DISTINCT FROM v.activo;

    INSERT INTO configuracion_auditoria (columna_id, evento_id, activo)
    SELECT v_col_id, v.evento_id, v.activo
      FROM (VALUES (1::smallint, p_insert), (2::smallint, p_update), (3::smallint, p_delete)) v(evento_id, activo)
     WHERE NOT EXISTS (SELECT 1 FROM configuracion_auditoria cf
                        WHERE cf.columna_id = v_col_id AND cf.evento_id = v.evento_id);

    UPDATE tabla_auditada
       SET modificado_por = session_user, fecha_modificacion = now(),
           estado = CASE WHEN estado = 'ACTIVO' THEN 'PENDIENTE' ELSE estado END
     WHERE tabla_id = v_tabla_id;

    RETURN v_col_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Atajo: configurar varias columnas (NULL = todas) con los mismos eventos
-- y aplicar de inmediato (genera el trigger)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_configurar_tabla(
    p_esquema text, p_tabla text,
    p_columnas text[] DEFAULT NULL,
    p_insert boolean DEFAULT true,
    p_update boolean DEFAULT true,
    p_delete boolean DEFAULT true,
    p_aplicar boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_tabla_id integer;
    v_col text;
    v_n integer := 0;
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    v_tabla_id := auditoria.fn_registrar_tabla(p_esquema, p_tabla);

    FOR v_col IN
        SELECT columna FROM auditoria.v_dic_columnas
         WHERE esquema = p_esquema AND tabla = p_tabla
           AND (p_columnas IS NULL OR columna = ANY (p_columnas))
         ORDER BY posicion
    LOOP
        PERFORM auditoria.fn_configurar_columna(p_esquema, p_tabla, v_col, p_insert, p_update, p_delete);
        v_n := v_n + 1;
    END LOOP;

    IF p_columnas IS NOT NULL AND v_n < cardinality(p_columnas) THEN
        RAISE EXCEPTION 'Alguna(s) de las columnas indicadas no existen en %.%: %',
            p_esquema, p_tabla, p_columnas;
    END IF;

    IF p_aplicar THEN
        RETURN auditoria.fn_generar_trigger(v_tabla_id);
    END IF;
    RETURN jsonb_build_object('exito', true, 'tabla_id', v_tabla_id, 'columnas', v_n,
                              'mensaje', 'Configuración guardada (sin aplicar)');
END;
$$;

-- ---------------------------------------------------------------------
-- Activar / desactivar la auditoría completa de una tabla
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_activar_tabla(p_tabla_id integer, p_activa boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    UPDATE tabla_auditada
       SET activa = p_activa, modificado_por = session_user, fecha_modificacion = now()
     WHERE tabla_id = p_tabla_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe configuración con tabla_id = %', p_tabla_id;
    END IF;

    IF p_activa THEN
        RETURN auditoria.fn_generar_trigger(p_tabla_id);
    ELSE
        RETURN auditoria.fn_eliminar_trigger(p_tabla_id);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Eliminar la configuración de una tabla.
-- Solo se permite si no tiene registros en bitácora (integridad);
-- en caso contrario debe desactivarse.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_eliminar_configuracion(p_tabla_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    IF EXISTS (SELECT 1 FROM bitacora_encabezado WHERE tabla_id = p_tabla_id) THEN
        RAISE EXCEPTION 'La tabla tiene registros en bitácora; no puede eliminarse, solo desactivarse'
            USING HINT = 'Use auditoria.fn_activar_tabla(id, false)';
    END IF;
    PERFORM auditoria.fn_eliminar_trigger(p_tabla_id);
    DELETE FROM tabla_auditada WHERE tabla_id = p_tabla_id;
    RETURN jsonb_build_object('exito', true, 'mensaje', 'Configuración eliminada');
END;
$$;

-- ---------------------------------------------------------------------
-- Validar configuración contra el diccionario (antes de activar)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_validar_configuracion(p_tabla_id integer)
RETURNS TABLE (nivel text, mensaje text)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    r_t tabla_auditada%ROWTYPE;
    r_c record;
BEGIN
    SELECT * INTO r_t FROM tabla_auditada WHERE tabla_id = p_tabla_id;
    IF NOT FOUND THEN
        nivel := 'ERROR'; mensaje := 'No existe la configuración ' || p_tabla_id; RETURN NEXT; RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = r_t.tabla_oid) THEN
        nivel := 'ERROR';
        mensaje := format('La tabla %I.%I ya no existe', r_t.esquema, r_t.tabla);
        RETURN NEXT; RETURN;
    END IF;

    IF auditoria.fn_dic_oid_tabla(r_t.esquema, r_t.tabla) IS DISTINCT FROM r_t.tabla_oid THEN
        nivel := 'AVISO';
        mensaje := 'La tabla fue renombrada o movida; se sincronizará el nombre';
        RETURN NEXT;
    END IF;

    FOR r_c IN
        SELECT ca.columna, ca.attnum, a.attname
          FROM columna_auditada ca
          LEFT JOIN pg_attribute a
                 ON a.attrelid = r_t.tabla_oid AND a.attnum = ca.attnum AND NOT a.attisdropped
         WHERE ca.tabla_id = p_tabla_id AND ca.activa AND NOT ca.eliminada
    LOOP
        IF r_c.attname IS NULL THEN
            nivel := 'ERROR';
            mensaje := format('La columna %s ya no existe en la tabla', r_c.columna);
            RETURN NEXT;
        ELSIF r_c.attname <> r_c.columna THEN
            nivel := 'AVISO';
            mensaje := format('La columna %s fue renombrada a %s', r_c.columna, r_c.attname);
            RETURN NEXT;
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1
                     FROM columna_auditada ca
                     JOIN configuracion_auditoria cf USING (columna_id)
                    WHERE ca.tabla_id = p_tabla_id AND ca.activa AND NOT ca.eliminada AND cf.activo) THEN
        nivel := 'ERROR';
        mensaje := 'No hay columnas con eventos activos para auditar';
        RETURN NEXT;
    END IF;

    IF auditoria.fn_dic_llave_primaria(r_t.tabla_oid) IS NULL THEN
        nivel := 'AVISO';
        mensaje := 'La tabla no tiene llave primaria: la bitácora no podrá identificar el registro por su llave';
        RETURN NEXT;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Sincronizar nombres (tabla/columnas renombradas) desde el diccionario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_sincronizar_tabla(p_tabla_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_oid oid;
BEGIN
    SELECT tabla_oid INTO v_oid FROM tabla_auditada WHERE tabla_id = p_tabla_id;

    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v_oid) THEN
        UPDATE tabla_auditada SET estado = 'HUERFANA', activa = false,
               ultimo_error = 'La tabla origen fue eliminada'
         WHERE tabla_id = p_tabla_id;
        RETURN;
    END IF;

    -- nombre de esquema/tabla actual
    UPDATE tabla_auditada t
       SET esquema = n.nspname, tabla = c.relname
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = t.tabla_oid AND t.tabla_id = p_tabla_id
       AND (t.esquema, t.tabla) IS DISTINCT FROM (n.nspname, c.relname);

    -- nombres y tipos de columnas (por attnum)
    UPDATE columna_auditada ca
       SET columna = a.attname, tipo_dato = format_type(a.atttypid, a.atttypmod), eliminada = false
      FROM pg_attribute a
     WHERE a.attrelid = v_oid AND a.attnum = ca.attnum AND NOT a.attisdropped
       AND ca.tabla_id = p_tabla_id;

    -- columnas que ya no existen
    UPDATE columna_auditada ca
       SET eliminada = true
     WHERE ca.tabla_id = p_tabla_id
       AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = v_oid AND a.attnum = ca.attnum AND NOT a.attisdropped);
END;
$$;

-- ---------------------------------------------------------------------
-- Parámetros globales (privacidad de IP, retención)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_set_parametro(p_clave text, p_valor text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    PERFORM auditoria.fn_verificar_admin();
    IF p_clave = 'ip_modo' AND p_valor NOT IN ('completa', 'anonimizada', 'ninguna') THEN
        RAISE EXCEPTION 'Valor inválido para ip_modo: % (use completa | anonimizada | ninguna)', p_valor;
    END IF;
    IF p_clave = 'dias_retencion' AND p_valor !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'dias_retencion debe ser un número entero';
    END IF;
    UPDATE parametro SET valor = p_valor WHERE clave = p_clave;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parámetro desconocido: %', p_clave;
    END IF;
END;
$$;
