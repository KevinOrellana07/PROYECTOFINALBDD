-- =====================================================================
-- Prueba 4: Seguridad, validaciones, dependencias y consultas
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\echo '--- Prueba 4: Seguridad, validaciones y consultas ---'

-- 4.1 Un usuario sin privilegios NO puede configurar auditoría
SET SESSION AUTHORIZATION vendedor;
DO $$
BEGIN
    BEGIN
        PERFORM auditoria.fn_configurar_columna('tienda', 'clientes', 'telefono');
        PERFORM pruebas.afirmar(false, 'Usuario sin privilegios no puede configurar');
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pruebas.afirmar(true, 'Usuario sin privilegios no puede configurar');
    END;
END $$;

-- 4.2 Nadie puede escribir directamente en la bitácora
DO $$
BEGIN
    BEGIN
        INSERT INTO auditoria.bitacora_encabezado (tabla_id, evento_id, usuario_id, estacion_id)
        VALUES (1, 1, 1, 1);
        PERFORM pruebas.afirmar(false, 'Escritura directa en bitácora denegada (usuario común)');
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pruebas.afirmar(true, 'Escritura directa en bitácora denegada (usuario común)');
    END;
END $$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION admin_auditoria;
DO $$
BEGIN
    BEGIN
        DELETE FROM auditoria.bitacora_detalle;
        PERFORM pruebas.afirmar(false, 'Administrador tampoco puede borrar la bitácora');
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pruebas.afirmar(true, 'Administrador tampoco puede borrar la bitácora');
    END;
END $$;
RESET SESSION AUTHORIZATION;

-- 4.3 Ni siquiera el superusuario puede alterar la bitácora (trigger de protección)
DO $$
BEGIN
    BEGIN
        UPDATE auditoria.bitacora_detalle SET valor_nuevo = 'alterado';
        PERFORM pruebas.afirmar(false, 'Bitácora inmutable incluso para superusuario');
    EXCEPTION WHEN insufficient_privilege THEN
        PERFORM pruebas.afirmar(true, 'Bitácora inmutable incluso para superusuario');
    END;
END $$;

-- 4.4 Validaciones contra el diccionario de datos
DO $$
BEGIN
    BEGIN
        PERFORM auditoria.fn_registrar_tabla('tienda', 'tabla_que_no_existe');
        PERFORM pruebas.afirmar(false, 'Valida existencia de tabla');
    EXCEPTION WHEN undefined_table THEN
        PERFORM pruebas.afirmar(true, 'Valida existencia de tabla');
    END;
    BEGIN
        PERFORM auditoria.fn_configurar_columna('pruebas', 'cuenta', 'columna_fantasma');
        PERFORM pruebas.afirmar(false, 'Valida existencia de columna');
    EXCEPTION WHEN undefined_column THEN
        PERFORM pruebas.afirmar(true, 'Valida existencia de columna');
    END;
END $$;

-- 4.5 Dependencias: renombrar y eliminar una columna auditada
ALTER TABLE pruebas.cuenta RENAME COLUMN estado TO situacion;
DO $$
BEGIN
    PERFORM pruebas.afirmar(
        EXISTS (SELECT 1 FROM auditoria.columna_auditada c JOIN auditoria.tabla_auditada t USING (tabla_id)
                 WHERE t.esquema = 'pruebas' AND t.tabla = 'cuenta' AND t.estado = 'ACTIVO'
                   AND c.columna = 'situacion'),
        'RENAME COLUMN: la configuración se sincroniza automáticamente');
END $$;
UPDATE pruebas.cuenta SET situacion = 'ACTIVA' WHERE cuenta_id = 1;

-- PostgreSQL protege la dependencia: el trigger (UPDATE OF situacion) depende de la columna
DO $$
BEGIN
    BEGIN
        ALTER TABLE pruebas.cuenta DROP COLUMN situacion;
        PERFORM pruebas.afirmar(false, 'DROP COLUMN de columna auditada es bloqueado por dependencia');
    EXCEPTION WHEN dependent_objects_still_exist THEN
        PERFORM pruebas.afirmar(true, 'DROP COLUMN de columna auditada es bloqueado por dependencia');
    END;
END $$;
-- Con CASCADE se elimina el trigger, y el event trigger lo regenera sin esa columna
ALTER TABLE pruebas.cuenta DROP COLUMN situacion CASCADE;
UPDATE pruebas.cuenta SET saldo = saldo + 1 WHERE cuenta_id = 1;   -- no debe fallar
DO $$
BEGIN
    PERFORM pruebas.afirmar(
        (SELECT estado FROM auditoria.tabla_auditada WHERE esquema = 'pruebas' AND tabla = 'cuenta'
            AND estado <> 'HUERFANA') = 'ACTIVO'
        AND (SELECT eliminada FROM auditoria.columna_auditada c JOIN auditoria.tabla_auditada t USING (tabla_id)
              WHERE t.esquema = 'pruebas' AND t.tabla = 'cuenta' AND t.estado <> 'HUERFANA'
                AND c.columna = 'situacion'),
        'DROP COLUMN: se marca la columna y el trigger se regenera sin romper DML');
    PERFORM pruebas.afirmar(
        (SELECT sincronizado FROM auditoria.v_estado_auditoria WHERE esquema = 'pruebas' AND tabla = 'cuenta'
            AND estado <> 'HUERFANA'),
        'Tabla de configuración refleja el estado real del trigger');
END $$;

-- 4.6 Consultas históricas
DO $$
BEGIN
    PERFORM pruebas.afirmar(
        (SELECT count(*) FROM auditoria.fn_historial_usuario('bodeguero')) >= 3,
        'Consulta por usuario retorna su historial');
    PERFORM pruebas.afirmar(
        (SELECT bool_and(columna = 'saldo') AND count(*) >= 3
           FROM auditoria.fn_historial_columna('pruebas', 'cuenta', 'saldo')),
        'Consulta por columna retorna solo cambios de esa columna');
    PERFORM pruebas.afirmar(
        (SELECT count(*) FROM auditoria.fn_consultar_bitacora(p_operacion => 'DELETE', p_tabla => 'cuenta')) >= 3,
        'Consulta filtrada por operación funciona');
END $$;

-- 4.7 Desactivar auditoría elimina el trigger; reactivar lo vuelve a crear
DO $$
DECLARE v_id integer;
BEGIN
    SELECT tabla_id INTO v_id FROM auditoria.tabla_auditada
     WHERE esquema = 'pruebas' AND tabla = 'cuenta' AND estado <> 'HUERFANA';
    PERFORM auditoria.fn_activar_tabla(v_id, false);
    PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM auditoria.v_dic_triggers
                                         WHERE esquema = 'pruebas' AND tabla = 'cuenta' AND es_autoaudit),
        'Desactivar elimina el trigger');
    PERFORM auditoria.fn_activar_tabla(v_id, true);
    PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM auditoria.v_dic_triggers
                                     WHERE esquema = 'pruebas' AND tabla = 'cuenta' AND es_autoaudit),
        'Reactivar vuelve a generar el trigger');
END $$;
