-- =====================================================================
-- AutoAudit - Ejemplo 3: consultas históricas parametrizadas
--   psql -h 127.0.0.1 -U auditor -d autoaudit_db -f ejemplos/03_consultas_ejemplo.sql
-- =====================================================================
\set ON_ERROR_STOP on

\echo '== 1. Historial completo de un USUARIO =='
SELECT fecha_hora::timestamp(0), operacion, tabla, columna, valor_anterior, valor_nuevo, equipo
  FROM auditoria.fn_historial_usuario('vendedor');

\echo '== 2. Todos los cambios de una COLUMNA específica =='
SELECT fecha_hora::timestamp(0), operacion, llave_registro, valor_anterior, valor_nuevo, usuario
  FROM auditoria.fn_historial_columna('tienda', 'productos', 'precio');

\echo '== 3. Con rango de fechas (últimas 24 horas) =='
SELECT count(*) AS cambios_ultimo_dia
  FROM auditoria.fn_historial_usuario('bodeguero', now() - interval '1 day', now());

\echo '== 4. Línea de tiempo de UN registro (por su llave primaria) =='
SELECT fecha_hora::timestamp(0), operacion, columna, valor_anterior, valor_nuevo, usuario
  FROM auditoria.fn_historial_registro('tienda', 'clientes', '{"cliente_id": 1}');

\echo '== 5. Búsqueda combinada (todos los filtros son opcionales) =='
SELECT fecha_hora::timestamp(0), usuario, tabla, columna, valor_anterior, valor_nuevo
  FROM auditoria.fn_consultar_bitacora(p_tabla => 'pedidos', p_operacion => 'UPDATE', p_limite => 20);

\echo '== 6. Registros eliminados (fila completa preservada) =='
SELECT fecha_hora::timestamp(0), tabla, usuario, registro_eliminado
  FROM auditoria.v_registros_eliminados;

\echo '== 7. Resumen de actividad por usuario =='
SELECT * FROM auditoria.v_resumen_usuarios ORDER BY operaciones DESC;

\echo '== 8. Actividad por estación de trabajo =='
SELECT s.direccion_ip, s.equipo, s.aplicacion, count(*) AS operaciones
  FROM auditoria.bitacora_encabezado e JOIN auditoria.estacion_trabajo s USING (estacion_id)
 GROUP BY 1, 2, 3 ORDER BY operaciones DESC;
