-- =====================================================================
-- AutoAudit - Ejemplo 2: generar actividad de varios usuarios
-- Simula operaciones de "vendedor" y "bodeguero" desde distintas
-- estaciones. Requiere superusuario (usa SET SESSION AUTHORIZATION):
--   sudo -u postgres psql -d autoaudit_db -f ejemplos/02_generar_actividad.sql
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---- Vendedor en la caja 1
SET SESSION AUTHORIZATION vendedor;
SET application_name = 'Sistema POS';
SET autoaudit.equipo = 'CAJA-01';

INSERT INTO tienda.clientes (nit, nombre, email, telefono, limite_credito)
VALUES ('6789012-3', 'Comercial La Ceiba', 'compras@laceiba.gt', '2233-4455', 15000);
UPDATE tienda.clientes SET limite_credito = 7500, telefono = '5555-1111' WHERE nit = '1234567-8';
UPDATE tienda.clientes SET email = 'carlos.mendez@empresa.gt' WHERE nit = '2345678-9';
UPDATE tienda.pedidos  SET estado = 'PAGADO', total = 7850.00 WHERE pedido_id = 1;
UPDATE tienda.pedidos  SET estado = 'PAGADO', total = 1350.00 WHERE pedido_id = 2;
UPDATE tienda.productos SET existencia = existencia - 1 WHERE codigo IN ('LAP-001', 'MON-024');
RESET SESSION AUTHORIZATION;

-- ---- Bodeguero en la bodega
SET SESSION AUTHORIZATION bodeguero;
SET application_name = 'Inventario';
SET autoaudit.equipo = 'PC-BODEGA';

INSERT INTO tienda.productos (codigo, nombre, categoria, precio, existencia)
VALUES ('CAM-720', 'Cámara web HD', 'Accesorios', 275.00, 40);
UPDATE tienda.productos SET precio = 6299.00 WHERE codigo = 'LAP-001';
UPDATE tienda.productos SET precio = 139.00, existencia = 150 WHERE codigo = 'MOU-202';
DELETE FROM tienda.productos WHERE codigo = 'IMP-300';
RESET SESSION AUTHORIZATION;

-- ---- Vendedor otra vez, desde otra caja
SET SESSION AUTHORIZATION vendedor;
SET application_name = 'Sistema POS';
SET autoaudit.equipo = 'CAJA-02';
UPDATE tienda.pedidos  SET estado = 'ENVIADO' WHERE pedido_id = 1;
UPDATE tienda.clientes SET activo = false WHERE nit = '4567890-1';
DELETE FROM tienda.pedidos WHERE pedido_id = 5;
RESET SESSION AUTHORIZATION;

-- ---- Administrador ajusta un salario
SET SESSION AUTHORIZATION admin_auditoria;
SET application_name = 'RRHH';
SET autoaudit.equipo = 'PC-GERENCIA';
UPDATE tienda.empleados SET salario = 5900.00 WHERE nombre = 'Luis Hernández';
RESET SESSION AUTHORIZATION;
RESET application_name;

SELECT operacion, tabla, columna, valor_anterior, valor_nuevo, usuario, equipo
  FROM auditoria.v_bitacora ORDER BY encabezado_id, detalle_id;
