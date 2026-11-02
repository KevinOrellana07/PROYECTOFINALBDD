-- =====================================================================
-- Prueba 5: Rendimiento con volumen creciente de registros auditados
-- Mide INSERT / UPDATE / DELETE masivos SIN auditoría y CON auditoría
-- sobre tablas idénticas, para 1.000, 10.000 y 50.000 registros.
-- Duración aproximada: 1 a 3 minutos.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\echo '--- Prueba 5: Rendimiento (puede tardar un par de minutos) ---'

CREATE TABLE pruebas.rend_sin (
    id serial PRIMARY KEY, nombre varchar(60), precio numeric(10,2), stock integer, nota text);
CREATE TABLE pruebas.rend_con (
    id serial PRIMARY KEY, nombre varchar(60), precio numeric(10,2), stock integer, nota text);

SELECT auditoria.fn_configurar_tabla('pruebas', 'rend_con', ARRAY['nombre', 'precio', 'stock']) ->> 'mensaje';

CREATE TABLE pruebas.resultado_rendimiento (
    registros integer, operacion text, ms_sin_auditoria numeric, ms_con_auditoria numeric,
    sobrecosto_ms_por_fila numeric GENERATED ALWAYS AS
        (round((ms_con_auditoria - ms_sin_auditoria) / registros, 4)) STORED);

CREATE TABLE pruebas.consulta_rendimiento (consulta text, ms numeric);
GRANT SELECT ON pruebas.resultado_rendimiento, pruebas.consulta_rendimiento TO PUBLIC;

CREATE FUNCTION pruebas.medir(p_sql text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    EXECUTE p_sql;
    RETURN round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1);
END $$;

DO $$
DECLARE
    n integer;
    v_sin numeric; v_con numeric;
    v_ins text := 'INSERT INTO pruebas.%s (nombre, precio, stock, nota)
                   SELECT ''Producto '' || g, (random()*1000)::numeric(10,2), (random()*100)::int, ''x''
                     FROM generate_series(1, %s) g';
    v_upd text := 'UPDATE pruebas.%s SET precio = precio * 1.10, stock = stock + 1';
    v_del text := 'DELETE FROM pruebas.%s';
BEGIN
    FOREACH n IN ARRAY ARRAY[1000, 10000, 50000] LOOP
        v_sin := pruebas.medir(format(v_ins, 'rend_sin', n));
        v_con := pruebas.medir(format(v_ins, 'rend_con', n));
        INSERT INTO pruebas.resultado_rendimiento VALUES (n, 'INSERT', v_sin, v_con);

        v_sin := pruebas.medir(format(v_upd, 'rend_sin'));
        v_con := pruebas.medir(format(v_upd, 'rend_con'));
        INSERT INTO pruebas.resultado_rendimiento VALUES (n, 'UPDATE', v_sin, v_con);

        v_sin := pruebas.medir(format(v_del, 'rend_sin'));
        v_con := pruebas.medir(format(v_del, 'rend_con'));
        INSERT INTO pruebas.resultado_rendimiento VALUES (n, 'DELETE', v_sin, v_con);
    END LOOP;

    -- Consultas sobre la bitácora ya poblada (usan índices)
    v_con := pruebas.medir($q$SELECT * FROM auditoria.fn_historial_registro('pruebas','rend_con','{"id": 30000}')$q$);
    INSERT INTO pruebas.consulta_rendimiento VALUES ('Historial de un registro', v_con);
    v_con := pruebas.medir($q$SELECT * FROM auditoria.fn_historial_usuario('vendedor')$q$);
    INSERT INTO pruebas.consulta_rendimiento VALUES ('Historial de un usuario', v_con);
    v_con := pruebas.medir($q$SELECT * FROM auditoria.fn_historial_columna('pruebas','cuenta','saldo')$q$);
    INSERT INTO pruebas.consulta_rendimiento VALUES ('Historial de una columna (pocos cambios)', v_con);
    v_con := pruebas.medir($q$SELECT * FROM auditoria.fn_consultar_bitacora(p_limite => 500)$q$);
    INSERT INTO pruebas.consulta_rendimiento VALUES ('Últimos 500 cambios (pantalla Bitácora)', v_con);

    -- 61.000 filas x 3 operaciones (INSERT, UPDATE, DELETE) = 183.000 encabezados
    PERFORM pruebas.afirmar(
        (SELECT count(*) FROM auditoria.bitacora_encabezado e
           JOIN auditoria.tabla_auditada t USING (tabla_id)
          WHERE t.esquema = 'pruebas' AND t.tabla = 'rend_con' AND t.estado <> 'HUERFANA') = 183000,
        'Rendimiento: todas las operaciones masivas quedaron auditadas (183.000)');
END $$;

\echo
\echo 'Resultados (ms). sobrecosto_ms_por_fila = costo adicional de auditar cada fila:'
SELECT registros, operacion, ms_sin_auditoria, ms_con_auditoria,
       round(ms_con_auditoria / NULLIF(ms_sin_auditoria, 0), 1) AS veces,
       sobrecosto_ms_por_fila
  FROM pruebas.resultado_rendimiento ORDER BY registros, operacion;

\echo 'Tiempo de consultas con la bitácora poblada (+183.000 operaciones):'
SELECT consulta, ms FROM pruebas.consulta_rendimiento;
