-- =====================================================================
-- AutoAudit - 08_datos_demo.sql : Base de datos de ejemplo "tienda"
-- Tablas de negocio sobre las que se demostrará la auditoría.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS tienda;
COMMENT ON SCHEMA tienda IS 'Esquema de demostración para AutoAudit';

CREATE TABLE IF NOT EXISTS tienda.clientes (
    cliente_id     serial        PRIMARY KEY,
    nit            varchar(15)   NOT NULL UNIQUE,
    nombre         varchar(100)  NOT NULL,
    email          varchar(120),
    telefono       varchar(20),
    direccion      varchar(200),
    limite_credito numeric(12,2) NOT NULL DEFAULT 0,
    activo         boolean       NOT NULL DEFAULT true,
    creado_en      timestamptz   NOT NULL DEFAULT now()
);
COMMENT ON TABLE tienda.clientes IS 'Clientes de la tienda';

CREATE TABLE IF NOT EXISTS tienda.productos (
    producto_id  serial        PRIMARY KEY,
    codigo       varchar(20)   NOT NULL UNIQUE,
    nombre       varchar(100)  NOT NULL,
    categoria    varchar(50)   NOT NULL,
    precio       numeric(10,2) NOT NULL CHECK (precio >= 0),
    existencia   integer       NOT NULL DEFAULT 0 CHECK (existencia >= 0),
    activo       boolean       NOT NULL DEFAULT true
);
COMMENT ON TABLE tienda.productos IS 'Catálogo de productos';

CREATE TABLE IF NOT EXISTS tienda.pedidos (
    pedido_id   serial        PRIMARY KEY,
    cliente_id  integer       NOT NULL REFERENCES tienda.clientes(cliente_id),
    fecha       date          NOT NULL DEFAULT current_date,
    estado      varchar(15)   NOT NULL DEFAULT 'PENDIENTE'
                CHECK (estado IN ('PENDIENTE','PAGADO','ENVIADO','ENTREGADO','ANULADO')),
    total       numeric(12,2) NOT NULL DEFAULT 0
);
COMMENT ON TABLE tienda.pedidos IS 'Encabezado de pedidos';

CREATE TABLE IF NOT EXISTS tienda.empleados (
    empleado_id  serial        PRIMARY KEY,
    nombre       varchar(100)  NOT NULL,
    puesto       varchar(50)   NOT NULL,
    salario      numeric(10,2) NOT NULL,
    fecha_ingreso date         NOT NULL DEFAULT current_date
);
COMMENT ON TABLE tienda.empleados IS 'Empleados (datos sensibles: salario)';

-- Datos iniciales (antes de activar la auditoría)
INSERT INTO tienda.clientes (nit, nombre, email, telefono, direccion, limite_credito) VALUES
 ('1234567-8', 'Ana Lucía Pérez',     'ana.perez@correo.gt',   '5555-1010', 'Zona 1, Guatemala',        5000),
 ('2345678-9', 'Carlos Méndez',       'cmendez@correo.gt',     '5555-2020', 'Zona 10, Guatemala',      12000),
 ('3456789-0', 'Distribuidora El Sol','ventas@elsol.com.gt',   '2222-3030', 'Mixco, Guatemala',        50000),
 ('4567890-1', 'María José García',   'mjgarcia@correo.gt',    '5555-4040', 'Antigua Guatemala',        3000),
 ('5678901-2', 'Jorge Castillo',      'jcastillo@correo.gt',   '5555-5050', 'Quetzaltenango',           8000)
ON CONFLICT (nit) DO NOTHING;

INSERT INTO tienda.productos (codigo, nombre, categoria, precio, existencia) VALUES
 ('LAP-001', 'Laptop 14" Core i5',      'Computadoras',  6500.00,  15),
 ('MON-024', 'Monitor 24" Full HD',     'Monitores',     1350.00,  30),
 ('TEC-101', 'Teclado mecánico',        'Accesorios',     425.00,  60),
 ('MOU-202', 'Mouse inalámbrico',       'Accesorios',     150.00, 120),
 ('IMP-300', 'Impresora multifunción',  'Impresoras',    1899.00,  10),
 ('SSD-512', 'Disco SSD 512 GB',        'Almacenamiento', 499.00,  45)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO tienda.pedidos (cliente_id, estado, total)
SELECT cliente_id, 'PENDIENTE', 0 FROM tienda.clientes
 WHERE NOT EXISTS (SELECT 1 FROM tienda.pedidos);

INSERT INTO tienda.empleados (nombre, puesto, salario)
SELECT * FROM (VALUES ('Luis Hernández', 'Vendedor',  5500.00),
                      ('Sofía Ramírez',  'Bodeguera', 4800.00),
                      ('Pedro Gómez',    'Gerente',  14000.00)) v
 WHERE NOT EXISTS (SELECT 1 FROM tienda.empleados);

-- Permisos de los usuarios operativos de la demo
GRANT USAGE ON SCHEMA tienda TO vendedor, bodeguero, autoaudit_admin, autoaudit_consulta;
GRANT SELECT ON ALL TABLES IN SCHEMA tienda TO vendedor, bodeguero, autoaudit_admin, autoaudit_consulta;
GRANT INSERT, UPDATE, DELETE ON tienda.clientes, tienda.pedidos TO vendedor;
GRANT INSERT, UPDATE, DELETE ON tienda.productos TO bodeguero;
GRANT UPDATE ON tienda.productos TO vendedor;            -- p.ej. descontar existencia
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA tienda TO autoaudit_admin;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA tienda TO vendedor, bodeguero, autoaudit_admin;
