-- =====================================================================
-- AutoAudit - 06_seguridad.sql : Permisos y protección de la bitácora
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- 1) Bitácora inmutable: nadie puede modificar ni borrar registros
--    (ni siquiera el dueño), salvo depuración explícita por superusuario.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_proteger_bitacora()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    IF current_setting('autoaudit.mantenimiento', true) = 'on'
       AND (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RETURN COALESCE(OLD, NEW);
    END IF;
    RAISE EXCEPTION 'La bitácora de auditoría es de solo inserción: % no permitido sobre %',
        TG_OP, TG_TABLE_NAME
        USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_proteger ON auditoria.bitacora_encabezado;
CREATE TRIGGER trg_proteger
    BEFORE UPDATE OR DELETE ON auditoria.bitacora_encabezado
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_proteger_bitacora();

DROP TRIGGER IF EXISTS trg_proteger ON auditoria.bitacora_detalle;
CREATE TRIGGER trg_proteger
    BEFORE UPDATE OR DELETE ON auditoria.bitacora_detalle
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_proteger_bitacora();

DROP TRIGGER IF EXISTS trg_proteger_truncate ON auditoria.bitacora_encabezado;
CREATE TRIGGER trg_proteger_truncate
    BEFORE TRUNCATE ON auditoria.bitacora_encabezado
    FOR EACH STATEMENT EXECUTE FUNCTION auditoria.fn_proteger_bitacora();

DROP TRIGGER IF EXISTS trg_proteger_truncate ON auditoria.bitacora_detalle;
CREATE TRIGGER trg_proteger_truncate
    BEFORE TRUNCATE ON auditoria.bitacora_detalle
    FOR EACH STATEMENT EXECUTE FUNCTION auditoria.fn_proteger_bitacora();

-- ---------------------------------------------------------------------
-- 2) Nadie tiene permisos por defecto
-- ---------------------------------------------------------------------
REVOKE ALL ON SCHEMA auditoria FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA auditoria FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA auditoria FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA auditoria FROM PUBLIC;

GRANT USAGE ON SCHEMA auditoria TO autoaudit_owner, autoaudit_admin, autoaudit_consulta;

-- ---------------------------------------------------------------------
-- 3) autoaudit_owner: dueño de los triggers generados.
--    ÚNICO rol con permiso de INSERT en la bitácora.
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT ON auditoria.bitacora_encabezado, auditoria.bitacora_detalle,
                        auditoria.usuario_auditado, auditoria.estacion_trabajo
      TO autoaudit_owner;
GRANT SELECT ON auditoria.parametro TO autoaudit_owner;
GRANT USAGE  ON SEQUENCE auditoria.bitacora_encabezado_encabezado_id_seq,
                         auditoria.bitacora_detalle_detalle_id_seq,
                         auditoria.usuario_auditado_usuario_id_seq,
                         auditoria.estacion_trabajo_estacion_id_seq
      TO autoaudit_owner;
GRANT EXECUTE ON FUNCTION auditoria.fn_crear_encabezado(integer, smallint, jsonb, jsonb, jsonb),
                          auditoria.fn_ip_cliente()
      TO autoaudit_owner;

-- ---------------------------------------------------------------------
-- 4) autoaudit_consulta: solo lectura de bitácora, configuración y diccionario
-- ---------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA auditoria TO autoaudit_consulta;
GRANT EXECUTE ON FUNCTION
      auditoria.fn_consultar_bitacora(text, text, text, text, text, timestamptz, timestamptz, integer),
      auditoria.fn_historial_usuario(text, timestamptz, timestamptz),
      auditoria.fn_historial_columna(text, text, text, timestamptz, timestamptz),
      auditoria.fn_historial_registro(text, text, jsonb),
      auditoria.fn_estadisticas(integer),
      auditoria.fn_validar_configuracion(integer),
      auditoria.fn_construir_sql_trigger(integer),
      auditoria.fn_es_admin(),
      auditoria.fn_dic_oid_tabla(text, text),
      auditoria.fn_dic_llave_primaria(oid)
      TO autoaudit_consulta, autoaudit_admin;

-- ---------------------------------------------------------------------
-- 5) autoaudit_admin: lectura + funciones de configuración.
--    NO recibe INSERT/UPDATE/DELETE directo sobre las tablas: toda
--    modificación pasa por las funciones (que validan y registran).
-- ---------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA auditoria TO autoaudit_admin;
GRANT EXECUTE ON FUNCTION
      auditoria.fn_verificar_admin(),
      auditoria.fn_registrar_tabla(text, text, text),
      auditoria.fn_configurar_columna(text, text, text, boolean, boolean, boolean),
      auditoria.fn_configurar_tabla(text, text, text[], boolean, boolean, boolean, boolean),
      auditoria.fn_activar_tabla(integer, boolean),
      auditoria.fn_eliminar_configuracion(integer),
      auditoria.fn_sincronizar_tabla(integer),
      auditoria.fn_generar_trigger(integer),
      auditoria.fn_eliminar_trigger(integer),
      auditoria.fn_regenerar_todos(),
      auditoria.fn_set_parametro(text, text)
      TO autoaudit_admin;

-- Las vistas del diccionario consultan pg_catalog (público), basta SELECT.
