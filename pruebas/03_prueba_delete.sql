-- =====================================================================
-- Prueba 3: DELETE preserva los datos en bitácora
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\echo '--- Prueba 3: DELETE ---'

SET SESSION AUTHORIZATION vendedor;
INSERT INTO pruebas.cuenta (titular, saldo, estado) VALUES ('Registro a eliminar', 999.99, 'ACTIVA');
DELETE FROM pruebas.cuenta WHERE titular = 'Registro a eliminar';
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    r_enc auditoria.bitacora_encabezado%ROWTYPE;
BEGIN
    SELECT * INTO r_enc FROM auditoria.bitacora_encabezado
     WHERE evento_id = 3 ORDER BY encabezado_id DESC LIMIT 1;

    PERFORM pruebas.afirmar(
        NOT EXISTS (SELECT 1 FROM pruebas.cuenta WHERE titular = 'Registro a eliminar'),
        'DELETE: el registro ya no existe en la tabla origen');
    PERFORM pruebas.afirmar(r_enc.encabezado_id IS NOT NULL, 'DELETE genera encabezado en bitácora');
    PERFORM pruebas.afirmar(
        r_enc.datos_anteriores->>'titular' = 'Registro a eliminar'
        AND r_enc.datos_anteriores->>'saldo' = '999.99'
        AND r_enc.datos_anteriores ? 'notas',
        'DELETE preserva la fila COMPLETA eliminada (incluye columnas no auditadas)',
        r_enc.datos_anteriores::text);
    PERFORM pruebas.afirmar(r_enc.datos_nuevos IS NULL, 'DELETE no tiene datos nuevos');
    PERFORM pruebas.afirmar(
        (SELECT count(*) FROM auditoria.bitacora_detalle
          WHERE encabezado_id = r_enc.encabezado_id AND valor_anterior IS NOT NULL AND valor_nuevo IS NULL) = 3,
        'DELETE guarda valor anterior de las 3 columnas auditadas');
    PERFORM pruebas.afirmar(
        (SELECT count(DISTINCT operacion) FROM auditoria.fn_historial_registro('pruebas', 'cuenta', r_enc.llave_registro)) = 2,
        'Historial del registro eliminado sigue disponible (INSERT + DELETE)');
    PERFORM pruebas.afirmar(
        EXISTS (SELECT 1 FROM auditoria.v_registros_eliminados WHERE encabezado_id = r_enc.encabezado_id),
        'Vista v_registros_eliminados muestra el registro');
END $$;
