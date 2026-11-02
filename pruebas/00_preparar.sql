-- =====================================================================
-- AutoAudit - Pruebas: preparación del entorno
-- Crea el esquema "pruebas", una tabla de prueba y la configura.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- Limpieza de ejecuciones anteriores
DO $$
DECLARE v_id integer;
BEGIN
    SELECT tabla_id INTO v_id FROM auditoria.tabla_auditada WHERE esquema = 'pruebas' AND tabla = 'cuenta';
    IF v_id IS NOT NULL THEN
        PERFORM auditoria.fn_eliminar_trigger(v_id);
    END IF;
END $$;
DROP SCHEMA IF EXISTS pruebas CASCADE;

CREATE SCHEMA pruebas;
GRANT USAGE ON SCHEMA pruebas TO PUBLIC;

-- Registro de resultados
CREATE TABLE pruebas.resultado (
    id        serial PRIMARY KEY,
    prueba    text NOT NULL,
    exito     boolean NOT NULL,
    detalle   text,
    fecha     timestamptz DEFAULT clock_timestamp()
);
GRANT INSERT, SELECT ON pruebas.resultado TO PUBLIC;
GRANT USAGE ON SEQUENCE pruebas.resultado_id_seq TO PUBLIC;

-- Afirmación: registra PASA/FALLA y lo muestra
CREATE FUNCTION pruebas.afirmar(p_condicion boolean, p_prueba text, p_detalle text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO pruebas.resultado (prueba, exito, detalle)
    VALUES (p_prueba, COALESCE(p_condicion, false), p_detalle);
    IF COALESCE(p_condicion, false) THEN
        RAISE WARNING '  [PASA]  %', p_prueba;
    ELSE
        RAISE WARNING '  [FALLA] %  %', p_prueba, COALESCE('(' || p_detalle || ')', '');
    END IF;
END $$;
GRANT EXECUTE ON FUNCTION pruebas.afirmar(boolean, text, text) TO PUBLIC;

-- Tabla de prueba: "notas" NO se audita
CREATE TABLE pruebas.cuenta (
    cuenta_id  serial PRIMARY KEY,
    titular    varchar(100) NOT NULL,
    saldo      numeric(12,2) NOT NULL DEFAULT 0,
    estado     varchar(10) NOT NULL DEFAULT 'ACTIVA',
    notas      text
);
GRANT SELECT, INSERT, UPDATE, DELETE ON pruebas.cuenta TO vendedor, bodeguero;
GRANT USAGE ON SEQUENCE pruebas.cuenta_cuenta_id_seq TO vendedor, bodeguero;

-- Configuración de auditoría: titular, saldo y estado (INSERT/UPDATE/DELETE)
SELECT auditoria.fn_configurar_tabla('pruebas', 'cuenta',
       ARRAY['titular', 'saldo', 'estado'], true, true, true) ->> 'mensaje' AS configuracion;
