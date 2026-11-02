-- =====================================================================
-- AutoAudit - Sistema de auditoría automatizado
-- 00_roles_y_bd.sql : Roles de seguridad, usuarios de demostración y BD
-- Ejecutar como superusuario (postgres) conectado a la BD "postgres":
--     sudo -u postgres psql -f sql/00_roles_y_bd.sql
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Roles de grupo (NOLOGIN)
--   autoaudit_owner    : dueño técnico de las funciones de trigger generadas.
--                        Es el ÚNICO que puede escribir en la bitácora.
--   autoaudit_admin    : administradores; pueden configurar la auditoría.
--   autoaudit_consulta : auditores; solo pueden consultar la bitácora.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_owner') THEN
        CREATE ROLE autoaudit_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_admin') THEN
        CREATE ROLE autoaudit_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_consulta') THEN
        CREATE ROLE autoaudit_consulta NOLOGIN;
    END IF;

    -- Usuarios de demostración (CAMBIE LAS CONTRASEÑAS en un entorno real)
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_auditoria') THEN
        CREATE ROLE admin_auditoria LOGIN PASSWORD 'Admin123!';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor') THEN
        CREATE ROLE auditor LOGIN PASSWORD 'Auditor123!';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vendedor') THEN
        CREATE ROLE vendedor LOGIN PASSWORD 'Vendedor123!';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bodeguero') THEN
        CREATE ROLE bodeguero LOGIN PASSWORD 'Bodega123!';
    END IF;
END
$$;

GRANT autoaudit_admin    TO admin_auditoria;
GRANT autoaudit_consulta TO admin_auditoria;   -- el admin también consulta
GRANT autoaudit_consulta TO auditor;

-- ---------------------------------------------------------------------
-- Base de datos del proyecto
-- ---------------------------------------------------------------------
SELECT 'CREATE DATABASE autoaudit_db ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'autoaudit_db')
\gexec

GRANT CONNECT ON DATABASE autoaudit_db
    TO autoaudit_admin, autoaudit_consulta, vendedor, bodeguero;
