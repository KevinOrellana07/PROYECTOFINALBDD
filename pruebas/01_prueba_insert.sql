-- =====================================================================
-- Prueba 1: INSERT queda registrado correctamente en bitácora
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\echo '--- Prueba 1: INSERT ---'

-- El cambio lo hace el usuario "vendedor" desde una aplicación identificada
SET SESSION AUTHORIZATION vendedor;
SET application_name = 'Pruebas AutoAudit';
SELECT set_config('autoaudit.equipo', 'PC-CAJA-01', false);
INSERT INTO pruebas.cuenta (titular, saldo, estado, notas)
VALUES ('Ana Pérez', 1500.00, 'ACTIVA', 'nota no auditada');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    v_enc auditoria.bitacora_encabezado%ROWTYPE;
    v_det integer;
BEGIN
    SELECT e.* INTO v_enc
      FROM auditoria.bitacora_encabezado e
      JOIN auditoria.tabla_auditada t USING (tabla_id)
     WHERE t.esquema = 'pruebas' AND t.tabla = 'cuenta' AND t.estado <> 'HUERFANA' AND e.evento_id = 1
     ORDER BY e.encabezado_id DESC LIMIT 1;

    PERFORM pruebas.afirmar(v_enc.encabezado_id IS NOT NULL, 'INSERT genera encabezado en bitácora');
    PERFORM pruebas.afirmar(v_enc.llave_registro = jsonb_build_object('cuenta_id', 1),
            'INSERT registra la llave primaria del registro', v_enc.llave_registro::text);
    PERFORM pruebas.afirmar(v_enc.datos_nuevos ->> 'titular' = 'Ana Pérez',
            'INSERT guarda la fila completa nueva (datos_nuevos)');

    SELECT count(*) INTO v_det FROM auditoria.bitacora_detalle WHERE encabezado_id = v_enc.encabezado_id;
    PERFORM pruebas.afirmar(v_det = 3, 'INSERT registra exactamente las 3 columnas configuradas', v_det || ' detalles');

    PERFORM pruebas.afirmar(
        (SELECT valor_nuevo FROM auditoria.v_bitacora
          WHERE encabezado_id = v_enc.encabezado_id AND columna = 'saldo') = '1500.00',
        'INSERT guarda valor nuevo de saldo = 1500.00');

    PERFORM pruebas.afirmar(
        NOT EXISTS (SELECT 1 FROM auditoria.v_bitacora
                     WHERE encabezado_id = v_enc.encabezado_id AND columna = 'notas'),
        'INSERT no registra columnas no configuradas (notas)');

    PERFORM pruebas.afirmar(
        (SELECT nombre_usuario FROM auditoria.usuario_auditado WHERE usuario_id = v_enc.usuario_id) = 'vendedor',
        'INSERT registra el usuario responsable (vendedor)');

    PERFORM pruebas.afirmar(
        (SELECT equipo || '|' || aplicacion FROM auditoria.estacion_trabajo
          WHERE estacion_id = v_enc.estacion_id) = 'PC-CAJA-01|Pruebas AutoAudit',
        'INSERT registra estación de trabajo (equipo y aplicación)');

    PERFORM pruebas.afirmar(v_enc.fecha_hora IS NOT NULL AND v_enc.transaccion_id IS NOT NULL,
        'INSERT registra fecha/hora y transacción');
END $$;
