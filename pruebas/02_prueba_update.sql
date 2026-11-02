-- =====================================================================
-- Prueba 2: UPDATE captura valor antiguo y valor nuevo
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\echo '--- Prueba 2: UPDATE ---'

CREATE TEMP TABLE _antes AS
SELECT coalesce(max(encabezado_id), 0) AS ultimo FROM auditoria.bitacora_encabezado;
GRANT SELECT ON _antes TO PUBLIC;

SET SESSION AUTHORIZATION bodeguero;
SELECT set_config('autoaudit.equipo', 'PC-BODEGA-02', false);

-- (a) cambia una columna auditada
UPDATE pruebas.cuenta SET saldo = 2500.75 WHERE cuenta_id = 1;
-- (b) cambia dos columnas auditadas en la misma sentencia
UPDATE pruebas.cuenta SET titular = 'Ana Lucía Pérez', estado = 'BLOQUEADA' WHERE cuenta_id = 1;
-- (c) cambia SOLO una columna no auditada  => no debe registrar nada
UPDATE pruebas.cuenta SET notas = 'otra nota' WHERE cuenta_id = 1;
-- (d) "actualiza" con el mismo valor        => no debe registrar nada
UPDATE pruebas.cuenta SET saldo = 2500.75 WHERE cuenta_id = 1;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    v_desde bigint := (SELECT ultimo FROM _antes);
    v_n     integer;
    r       record;
BEGIN
    SELECT count(*) INTO v_n FROM auditoria.bitacora_encabezado
     WHERE encabezado_id > v_desde AND evento_id = 2;
    PERFORM pruebas.afirmar(v_n = 2, 'UPDATE: solo 2 de 4 sentencias generan bitácora (cambios reales en columnas auditadas)', v_n || ' encabezados');

    SELECT * INTO r FROM auditoria.v_bitacora
     WHERE encabezado_id > v_desde AND columna = 'saldo' AND operacion = 'UPDATE';
    PERFORM pruebas.afirmar(r.valor_anterior = '1500.00' AND r.valor_nuevo = '2500.75',
        'UPDATE captura valor anterior (1500.00) y nuevo (2500.75) de saldo',
        r.valor_anterior || ' -> ' || r.valor_nuevo);
    PERFORM pruebas.afirmar(r.usuario = 'bodeguero' AND r.equipo = 'PC-BODEGA-02',
        'UPDATE registra usuario (bodeguero) y estación (PC-BODEGA-02)');

    SELECT count(*) INTO v_n FROM auditoria.v_bitacora
     WHERE encabezado_id = (SELECT max(encabezado_id) FROM auditoria.bitacora_encabezado WHERE encabezado_id > v_desde);
    PERFORM pruebas.afirmar(v_n = 2, 'UPDATE de 2 columnas genera 1 encabezado con 2 detalles', v_n || ' detalles');

    PERFORM pruebas.afirmar(
        EXISTS (SELECT 1 FROM auditoria.v_bitacora
                 WHERE encabezado_id > v_desde AND columna = 'estado'
                   AND valor_anterior = 'ACTIVA' AND valor_nuevo = 'BLOQUEADA'),
        'UPDATE captura estado ACTIVA -> BLOQUEADA');

    PERFORM pruebas.afirmar(
        NOT EXISTS (SELECT 1 FROM auditoria.v_bitacora
                     WHERE encabezado_id > v_desde AND columna = 'notas'),
        'UPDATE de columna no auditada (notas) no se registra');

    PERFORM pruebas.afirmar(
        (SELECT datos_anteriores->>'saldo' FROM auditoria.bitacora_encabezado
          WHERE encabezado_id > v_desde ORDER BY encabezado_id LIMIT 1) = '1500.00',
        'UPDATE guarda la fila completa anterior (datos_anteriores)');
END $$;
