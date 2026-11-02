-- =====================================================================
-- AutoAudit - 09_comentarios.sql : Descripción de columnas
-- Alimenta el diccionario de datos (pg_description), que se consulta
-- con docs/diccionario_datos.sql para generar la documentación.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

COMMENT ON COLUMN auditoria.evento.evento_id   IS 'Identificador del evento (1 INSERT, 2 UPDATE, 3 DELETE)';
COMMENT ON COLUMN auditoria.evento.codigo      IS 'Código de la operación DML';
COMMENT ON COLUMN auditoria.evento.descripcion IS 'Descripción legible del evento';

COMMENT ON COLUMN auditoria.tabla_auditada.tabla_id          IS 'Identificador de la configuración de la tabla';
COMMENT ON COLUMN auditoria.tabla_auditada.tabla_oid         IS 'OID de la tabla en pg_class; identifica la tabla aunque se renombre';
COMMENT ON COLUMN auditoria.tabla_auditada.esquema           IS 'Esquema de la tabla origen';
COMMENT ON COLUMN auditoria.tabla_auditada.tabla             IS 'Nombre de la tabla origen';
COMMENT ON COLUMN auditoria.tabla_auditada.descripcion       IS 'Motivo o descripción de la auditoría';
COMMENT ON COLUMN auditoria.tabla_auditada.activa            IS 'Interruptor maestro: si es falso no existe trigger';
COMMENT ON COLUMN auditoria.tabla_auditada.estado            IS 'PENDIENTE, ACTIVO, INACTIVO, ERROR o HUERFANA (tabla origen eliminada)';
COMMENT ON COLUMN auditoria.tabla_auditada.funcion_trigger   IS 'Nombre de la función PL/pgSQL generada en el esquema auditoria';
COMMENT ON COLUMN auditoria.tabla_auditada.trigger_nombre    IS 'Nombre del trigger generado en la tabla origen (trg_autoaudit)';
COMMENT ON COLUMN auditoria.tabla_auditada.sql_generado      IS 'Último código SQL generado y aplicado';
COMMENT ON COLUMN auditoria.tabla_auditada.fecha_generacion  IS 'Fecha y hora de la última generación exitosa';
COMMENT ON COLUMN auditoria.tabla_auditada.ultimo_error      IS 'Último error de validación o generación';
COMMENT ON COLUMN auditoria.tabla_auditada.creado_por        IS 'Usuario que registró la tabla';
COMMENT ON COLUMN auditoria.tabla_auditada.fecha_creacion    IS 'Fecha de registro';
COMMENT ON COLUMN auditoria.tabla_auditada.modificado_por    IS 'Último usuario que modificó la configuración';
COMMENT ON COLUMN auditoria.tabla_auditada.fecha_modificacion IS 'Fecha de la última modificación';

COMMENT ON COLUMN auditoria.columna_auditada.columna_id     IS 'Identificador de la columna auditada';
COMMENT ON COLUMN auditoria.columna_auditada.tabla_id       IS 'Tabla a la que pertenece (FK tabla_auditada)';
COMMENT ON COLUMN auditoria.columna_auditada.columna        IS 'Nombre actual de la columna';
COMMENT ON COLUMN auditoria.columna_auditada.attnum         IS 'Número de columna en pg_attribute; sobrevive a un RENAME';
COMMENT ON COLUMN auditoria.columna_auditada.tipo_dato      IS 'Tipo de dato según el diccionario';
COMMENT ON COLUMN auditoria.columna_auditada.activa         IS 'Indica si la columna participa en la auditoría';
COMMENT ON COLUMN auditoria.columna_auditada.eliminada      IS 'La columna ya no existe en la tabla origen (DROP COLUMN)';
COMMENT ON COLUMN auditoria.columna_auditada.fecha_creacion IS 'Fecha de registro';

COMMENT ON COLUMN auditoria.configuracion_auditoria.configuracion_id   IS 'Identificador de la configuración columna-evento';
COMMENT ON COLUMN auditoria.configuracion_auditoria.columna_id         IS 'Columna configurada (FK columna_auditada)';
COMMENT ON COLUMN auditoria.configuracion_auditoria.evento_id          IS 'Evento que se audita (FK evento)';
COMMENT ON COLUMN auditoria.configuracion_auditoria.activo             IS 'Si el evento se registra para esa columna';
COMMENT ON COLUMN auditoria.configuracion_auditoria.fecha_creacion     IS 'Fecha de creación';
COMMENT ON COLUMN auditoria.configuracion_auditoria.fecha_modificacion IS 'Fecha de la última activación/desactivación';

COMMENT ON COLUMN auditoria.usuario_auditado.usuario_id        IS 'Identificador del usuario auditado';
COMMENT ON COLUMN auditoria.usuario_auditado.nombre_usuario    IS 'Usuario de PostgreSQL (session_user) que realizó cambios';
COMMENT ON COLUMN auditoria.usuario_auditado.primera_actividad IS 'Primera vez que aparece en la bitácora';

COMMENT ON COLUMN auditoria.estacion_trabajo.estacion_id       IS 'Identificador de la estación';
COMMENT ON COLUMN auditoria.estacion_trabajo.direccion_ip      IS 'IP de la conexión (inet_client_addr), "local" si es socket, según política de privacidad';
COMMENT ON COLUMN auditoria.estacion_trabajo.equipo            IS 'Nombre del equipo informado por la aplicación (autoaudit.equipo)';
COMMENT ON COLUMN auditoria.estacion_trabajo.aplicacion        IS 'application_name de la conexión';
COMMENT ON COLUMN auditoria.estacion_trabajo.primera_actividad IS 'Primera vez que aparece en la bitácora';

COMMENT ON COLUMN auditoria.bitacora_encabezado.encabezado_id      IS 'Identificador de la operación';
COMMENT ON COLUMN auditoria.bitacora_encabezado.fecha_hora         IS 'Fecha y hora exacta del cambio';
COMMENT ON COLUMN auditoria.bitacora_encabezado.tabla_id           IS 'Tabla afectada (FK tabla_auditada)';
COMMENT ON COLUMN auditoria.bitacora_encabezado.evento_id          IS 'Operación realizada (FK evento)';
COMMENT ON COLUMN auditoria.bitacora_encabezado.usuario_id         IS 'Usuario responsable (FK usuario_auditado)';
COMMENT ON COLUMN auditoria.bitacora_encabezado.estacion_id        IS 'Estación de origen (FK estacion_trabajo)';
COMMENT ON COLUMN auditoria.bitacora_encabezado.usuario_aplicacion IS 'Usuario de la aplicación, si la aplicación lo informa';
COMMENT ON COLUMN auditoria.bitacora_encabezado.transaccion_id     IS 'Identificador de la transacción (txid)';
COMMENT ON COLUMN auditoria.bitacora_encabezado.llave_registro     IS 'Llave primaria del registro afectado en formato JSON';
COMMENT ON COLUMN auditoria.bitacora_encabezado.datos_anteriores   IS 'Fila completa antes del cambio (UPDATE/DELETE)';
COMMENT ON COLUMN auditoria.bitacora_encabezado.datos_nuevos       IS 'Fila completa después del cambio (INSERT/UPDATE)';

COMMENT ON COLUMN auditoria.bitacora_detalle.detalle_id       IS 'Identificador del detalle';
COMMENT ON COLUMN auditoria.bitacora_detalle.encabezado_id    IS 'Operación a la que pertenece (FK bitacora_encabezado)';
COMMENT ON COLUMN auditoria.bitacora_detalle.configuracion_id IS 'Configuración columna-evento usada (FK configuracion_auditoria)';
COMMENT ON COLUMN auditoria.bitacora_detalle.columna_id       IS 'Columna afectada (FK columna_auditada)';
COMMENT ON COLUMN auditoria.bitacora_detalle.valor_anterior   IS 'Valor antes del cambio, como texto';
COMMENT ON COLUMN auditoria.bitacora_detalle.valor_nuevo      IS 'Valor después del cambio, como texto';

COMMENT ON COLUMN auditoria.log_generacion.log_id        IS 'Identificador del registro';
COMMENT ON COLUMN auditoria.log_generacion.fecha_hora    IS 'Fecha y hora de la acción';
COMMENT ON COLUMN auditoria.log_generacion.tabla_id      IS 'Tabla relacionada (FK tabla_auditada)';
COMMENT ON COLUMN auditoria.log_generacion.objeto        IS 'Objeto afectado (función o columna)';
COMMENT ON COLUMN auditoria.log_generacion.accion        IS 'GENERAR, ELIMINAR, VALIDAR, SINCRONIZAR, DDL o PURGAR';
COMMENT ON COLUMN auditoria.log_generacion.exito         IS 'Resultado de la acción';
COMMENT ON COLUMN auditoria.log_generacion.mensaje       IS 'Mensaje o error';
COMMENT ON COLUMN auditoria.log_generacion.sql_ejecutado IS 'Código SQL ejecutado';
COMMENT ON COLUMN auditoria.log_generacion.usuario       IS 'Usuario que ejecutó la acción';

COMMENT ON COLUMN auditoria.parametro.clave       IS 'Nombre del parámetro';
COMMENT ON COLUMN auditoria.parametro.valor       IS 'Valor configurado';
COMMENT ON COLUMN auditoria.parametro.descripcion IS 'Descripción del parámetro';
