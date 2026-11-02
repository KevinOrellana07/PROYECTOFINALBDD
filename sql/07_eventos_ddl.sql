-- =====================================================================
-- AutoAudit - 07_eventos_ddl.sql : Gestión de dependencias
-- Event triggers que mantienen la configuración coherente cuando las
-- tablas origen cambian de estructura (DROP TABLE, DROP COLUMN,
-- RENAME, ALTER TYPE...). Requiere superusuario.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- DROP de tablas / columnas auditadas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_evt_sql_drop()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_dropped_objects()
              WHERE object_type IN ('table', 'table column')
    LOOP
        IF r.object_type = 'table' THEN
            UPDATE tabla_auditada
               SET estado = 'HUERFANA', activa = false,
                   ultimo_error = 'La tabla origen fue eliminada el ' || to_char(now(), 'YYYY-MM-DD HH24:MI:SS')
             WHERE tabla_oid = r.objid;
            IF FOUND THEN
                INSERT INTO log_generacion (tabla_id, objeto, accion, exito, mensaje)
                SELECT tabla_id, r.object_identity, 'DDL', true,
                       'DROP TABLE detectado: configuración marcada como HUERFANA. La bitácora se conserva.'
                  FROM tabla_auditada WHERE tabla_oid = r.objid;
            END IF;
        ELSE  -- table column
            UPDATE columna_auditada ca
               SET eliminada = true
              FROM tabla_auditada t
             WHERE t.tabla_id = ca.tabla_id AND t.tabla_oid = r.objid AND ca.attnum = r.objsubid;
            IF FOUND THEN
                INSERT INTO log_generacion (tabla_id, objeto, accion, exito, mensaje)
                SELECT tabla_id, r.object_identity, 'DDL', true,
                       'DROP COLUMN detectado: columna marcada como eliminada; se regenera el trigger.'
                  FROM tabla_auditada WHERE tabla_oid = r.objid;
            END IF;
        END IF;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'AutoAudit (sql_drop): %', SQLERRM;   -- nunca bloquea el DDL del usuario
END;
$$;

-- ---------------------------------------------------------------------
-- ALTER TABLE sobre tablas auditadas => sincronizar y regenerar trigger
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria.fn_evt_ddl_end()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    r   record;
    v_id integer;
    v_res jsonb;
BEGIN
    FOR r IN SELECT DISTINCT objid FROM pg_event_trigger_ddl_commands()
              WHERE command_tag = 'ALTER TABLE' AND object_type IN ('table', 'table column')
    LOOP
        SELECT tabla_id INTO v_id FROM tabla_auditada
         WHERE tabla_oid = r.objid AND activa AND estado <> 'HUERFANA';
        CONTINUE WHEN v_id IS NULL;

        PERFORM auditoria.fn_sincronizar_tabla(v_id);
        v_res := auditoria.fn_generar_trigger_interno(v_id);
        INSERT INTO log_generacion (tabla_id, accion, exito, mensaje)
        VALUES (v_id, 'SINCRONIZAR', (v_res->>'exito')::boolean,
                'ALTER TABLE detectado: ' || COALESCE(v_res->>'mensaje', ''));
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'AutoAudit (ddl_command_end): %', SQLERRM;
END;
$$;

DROP EVENT TRIGGER IF EXISTS evt_autoaudit_drop;
CREATE EVENT TRIGGER evt_autoaudit_drop ON sql_drop
    EXECUTE FUNCTION auditoria.fn_evt_sql_drop();

DROP EVENT TRIGGER IF EXISTS evt_autoaudit_alter;
CREATE EVENT TRIGGER evt_autoaudit_alter ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE FUNCTION auditoria.fn_evt_ddl_end();
