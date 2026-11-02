-- =====================================================================
-- AutoAudit - Ejemplo 1: configurar la auditoría de la tienda demo
-- Ejecutar como admin_auditoria (o postgres):
--   psql -h 127.0.0.1 -U admin_auditoria -d autoaudit_db -f ejemplos/01_configurar_demo.sql
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- 1) Consultar el diccionario de datos: ¿qué tablas y columnas existen?
SELECT esquema, tabla, num_columnas, tiene_pk, estado_auditoria
  FROM auditoria.v_dic_tablas ORDER BY esquema, tabla;

SELECT posicion, columna, tipo_dato, es_pk, admite_nulos
  FROM auditoria.v_dic_columnas
 WHERE esquema = 'tienda' AND tabla = 'clientes' ORDER BY posicion;

-- 2) Forma rápida: varias columnas con los mismos eventos y aplicar de inmediato
SELECT auditoria.fn_configurar_tabla('tienda', 'clientes',
       ARRAY['nombre', 'email', 'telefono', 'limite_credito', 'activo'],
       p_insert => true, p_update => true, p_delete => true) ->> 'mensaje' AS clientes;

-- 3) Forma granular: eventos distintos por columna, luego generar
SELECT auditoria.fn_registrar_tabla('tienda', 'productos', 'Control de precios e inventario');
SELECT auditoria.fn_configurar_columna('tienda', 'productos', 'nombre',     true,  true,  true);
SELECT auditoria.fn_configurar_columna('tienda', 'productos', 'precio',     true,  true,  true);
SELECT auditoria.fn_configurar_columna('tienda', 'productos', 'existencia', false, true,  false); -- solo cambios
SELECT auditoria.fn_generar_trigger(tabla_id) ->> 'mensaje' AS productos
  FROM auditoria.tabla_auditada WHERE esquema = 'tienda' AND tabla = 'productos' AND estado <> 'HUERFANA';

-- 4) Datos sensibles: salario de empleados (solo UPDATE y DELETE)
SELECT auditoria.fn_configurar_tabla('tienda', 'empleados', ARRAY['salario', 'puesto'],
       p_insert => false, p_update => true, p_delete => true) ->> 'mensaje' AS empleados;

-- 5) Pedidos: cambios de estado y total
SELECT auditoria.fn_configurar_tabla('tienda', 'pedidos', ARRAY['estado', 'total']) ->> 'mensaje' AS pedidos;

-- 6) Verificar el estado: configuración vs. triggers reales
SELECT esquema, tabla, estado, eventos, columnas_activas, trigger_existe, sincronizado
  FROM auditoria.v_estado_auditoria WHERE estado <> 'HUERFANA' ORDER BY tabla;
