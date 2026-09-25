-- =====================================================================
--  Esquema "monitoreo": puente entre los LOGS (archivos) y Grafana/Jupyter.
--
--  Mecanismo:  Nginx/Apache escriben logs TSV en volúmenes Docker compartidos
--              -> PostgreSQL los monta en solo lectura (/var/log/fuentes/...)
--              -> file_fdw los expone como TABLAS FORÁNEAS (se leen en cada consulta)
--              -> vistas tipadas (timestamps, enteros, clase de estado HTTP...)
--              -> Grafana (datasource PostgreSQL aprovisionado) y Jupyter (psycopg2)
--
--  Además expone, mediante funciones SECURITY DEFINER, datos de actividad del
--  propio Joomla (tablas #__action_logs, #__content, #__session) sin conceder a
--  los lectores acceso directo a las tablas del CMS (p. ej. #__users con hashes).
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE SERVER fuentes_log FOREIGN DATA WRAPPER file_fdw;

-- ---------------------------------------------------------------------
-- 1. Tablas foráneas sobre los archivos de log (todas las columnas text;
--    la conversión de tipos se hace en las vistas para tolerar valores "-")
--    encoding LATIN1: cualquier byte es válido -> una línea con bytes raros
--    nunca rompe la lectura completa del archivo.
-- ---------------------------------------------------------------------
CREATE FOREIGN TABLE monitoreo.ft_nginx_access (
    msec                   text,
    time_iso               text,
    remote_addr            text,
    x_forwarded_for        text,
    metodo                 text,
    uri                    text,
    protocolo              text,
    estado                 text,
    bytes                  text,
    request_time           text,
    upstream_addr          text,
    upstream_status        text,
    upstream_response_time text,
    upstream_connect_time  text,
    conexion_id            text,
    conexion_peticiones    text,
    servicio               text,
    host                   text,
    referer                text,
    user_agent             text
) SERVER fuentes_log
  OPTIONS (filename '/var/log/fuentes/nginx/access.log',
           format 'text', delimiter E'\t', encoding 'LATIN1');

CREATE FOREIGN TABLE monitoreo.ft_joomla_apache (
    fecha          text,
    ip_cliente     text,
    ip_par_tcp     text,
    x_forwarded_proto text,
    metodo         text,
    uri            text,
    protocolo      text,
    estado         text,
    bytes          text,
    duracion_us    text,
    keepalive_n    text,
    referer        text,
    user_agent     text
) SERVER fuentes_log
  OPTIONS (filename '/var/log/fuentes/joomla/apache_access.log',
           format 'text', delimiter E'\t', encoding 'LATIN1');

-- ---------------------------------------------------------------------
-- 2. Lectura tolerante a fallos: si el archivo aún no existe (Nginx no ha
--    arrancado) o una línea está mal formada, se devuelve vacío + WARNING
--    en lugar de un error que dejaría los paneles en rojo.
-- ---------------------------------------------------------------------
CREATE FUNCTION monitoreo.leer_nginx() RETURNS SETOF monitoreo.ft_nginx_access
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, monitoreo AS $$
BEGIN
    IF pg_stat_file('/var/log/fuentes/nginx/access.log', true) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM monitoreo.ft_nginx_access;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'No se pudo leer el log de Nginx: %', SQLERRM;
    RETURN;
END $$;

CREATE FUNCTION monitoreo.leer_joomla_apache() RETURNS SETOF monitoreo.ft_joomla_apache
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, monitoreo AS $$
BEGIN
    IF pg_stat_file('/var/log/fuentes/joomla/apache_access.log', true) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM monitoreo.ft_joomla_apache;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'No se pudo leer el log de Apache/Joomla: %', SQLERRM;
    RETURN;
END $$;

-- ---------------------------------------------------------------------
-- 3. Vistas tipadas de los logs
-- ---------------------------------------------------------------------
CREATE VIEW monitoreo.v_nginx_accesos AS
SELECT
    to_timestamp(msec::double precision)                          AS ts,
    remote_addr                                                   AS ip_origen,
    NULLIF(x_forwarded_for, '-')                                  AS x_forwarded_for,
    metodo,
    uri,
    split_part(uri, '?', 1)                                       AS ruta,
    protocolo,
    estado::int                                                   AS estado,
    left(estado, 1) || 'xx'                                       AS clase_estado,
    bytes::bigint                                                 AS bytes,
    request_time::numeric                                         AS tiempo_total_s,
    NULLIF(upstream_addr, '-')                                    AS upstream_addr,
    CASE WHEN upstream_status ~ '^\d{3}$' THEN upstream_status::int END            AS upstream_estado,
    CASE WHEN upstream_response_time ~ '^[0-9.]+$' THEN upstream_response_time::numeric END AS upstream_tiempo_s,
    CASE WHEN upstream_connect_time  ~ '^[0-9.]+$' THEN upstream_connect_time::numeric  END AS upstream_connect_s,
    conexion_id::bigint                                           AS conexion_id,
    conexion_peticiones::int                                      AS peticiones_en_conexion,
    servicio,
    host,
    NULLIF(referer, '-')                                          AS referer,
    user_agent
FROM monitoreo.leer_nginx()
WHERE msec ~ '^[0-9.]+$';

CREATE VIEW monitoreo.v_joomla_apache AS
SELECT
    fecha::timestamptz                                            AS ts,
    ip_cliente,                    -- IP original (mod_remoteip + X-Forwarded-For)
    ip_par_tcp,                    -- IP del par TCP real = contenedor nginx
    NULLIF(x_forwarded_proto, '-')                                AS x_forwarded_proto,
    metodo,
    uri,
    split_part(uri, '?', 1)                                       AS ruta,
    protocolo,
    estado::int                                                   AS estado,
    left(estado, 1) || 'xx'                                       AS clase_estado,
    CASE WHEN bytes ~ '^\d+$' THEN bytes::bigint ELSE 0 END       AS bytes,
    round(duracion_us::numeric / 1000, 2)                         AS duracion_ms,
    keepalive_n::int                                              AS peticiones_keepalive,
    NULLIF(referer, '-')                                          AS referer,
    user_agent
FROM monitoreo.leer_joomla_apache()
WHERE estado ~ '^\d{3}$';

-- ---------------------------------------------------------------------
-- 4. Actividad del CMS (tablas de Joomla). Se usa SQL dinámico porque las
--    tablas aún no existen cuando se ejecuta este script (Joomla se instala
--    después); si no existen todavía, se devuelve vacío.
-- ---------------------------------------------------------------------
CREATE FUNCTION monitoreo.actividad_joomla()
RETURNS TABLE (fecha timestamptz, usuario text, extension text, accion text,
               item_id int, ip text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
    p text := (SELECT valor FROM monitoreo.parametros WHERE clave = 'joomla_prefix');
BEGIN
    RETURN QUERY EXECUTE format($q$
        SELECT (a.log_date AT TIME ZONE 'UTC')::timestamptz,
               COALESCE(u.username, a.message::json->>'username', 'invitado')::text,
               a.extension::text,
               lower(replace(regexp_replace(a.message_language_key,
                     '^PLG_(ACTIONLOG|SYSTEM_ACTIONLOGS)_(JOOMLA_)?', ''), '_', ' '))::text,
               a.item_id::int,
               a.ip_address::text
        FROM %I a LEFT JOIN %I u ON u.id = a.user_id
    $q$, p || 'action_logs', p || 'users');
EXCEPTION WHEN undefined_table THEN
    RETURN;
END $$;

CREATE FUNCTION monitoreo.articulos_joomla()
RETURNS TABLE (id int, titulo text, alias text, hits bigint, creado timestamptz,
               publicado boolean, destacado boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
    p text := (SELECT valor FROM monitoreo.parametros WHERE clave = 'joomla_prefix');
BEGIN
    RETURN QUERY EXECUTE format($q$
        SELECT c.id::int, c.title::text, c.alias::text, c.hits::bigint,
               (c.created AT TIME ZONE 'UTC')::timestamptz,
               c.state = 1, c.featured = 1
        FROM %I c
    $q$, p || 'content');
EXCEPTION WHEN undefined_table THEN
    RETURN;
END $$;

CREATE FUNCTION monitoreo.sesiones_joomla()
RETURNS TABLE (cliente text, tipo text, ultima_actividad timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
    p text := (SELECT valor FROM monitoreo.parametros WHERE clave = 'joomla_prefix');
BEGIN
    RETURN QUERY EXECUTE format($q$
        SELECT CASE s.client_id WHEN 0 THEN 'sitio' WHEN 1 THEN 'administrador' ELSE 'api' END,
               CASE s.guest WHEN 1 THEN 'invitado' ELSE 'autenticado' END,
               to_timestamp(s.time::double precision)
        FROM %I s
    $q$, p || 'session');
EXCEPTION WHEN undefined_table THEN
    RETURN;
END $$;

CREATE VIEW monitoreo.v_actividad_joomla AS SELECT * FROM monitoreo.actividad_joomla();
CREATE VIEW monitoreo.v_articulos_joomla AS SELECT * FROM monitoreo.articulos_joomla();
CREATE VIEW monitoreo.v_sesiones_joomla  AS SELECT * FROM monitoreo.sesiones_joomla();

-- ---------------------------------------------------------------------
-- 5. Conexiones TCP activas al servidor PostgreSQL (evidencia Capa 3/4)
-- ---------------------------------------------------------------------
CREATE VIEW monitoreo.v_conexiones_pg AS
SELECT pid,
       usename::text          AS usuario,
       application_name       AS aplicacion,
       host(client_addr)      AS ip_cliente,
       client_port            AS puerto_cliente,
       state                  AS estado,
       backend_start          AS inicio_conexion,
       now() - backend_start  AS antiguedad
FROM pg_stat_activity
WHERE backend_type = 'client backend';

-- ---------------------------------------------------------------------
-- 6. Permisos: los lectores solo ven el esquema monitoreo (vistas + funciones)
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA monitoreo FROM PUBLIC;
GRANT USAGE ON SCHEMA monitoreo TO lectores_monitoreo;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA monitoreo TO lectores_monitoreo;
GRANT SELECT ON monitoreo.v_nginx_accesos, monitoreo.v_joomla_apache,
                monitoreo.v_actividad_joomla, monitoreo.v_articulos_joomla,
                monitoreo.v_sesiones_joomla, monitoreo.v_conexiones_pg
      TO lectores_monitoreo;
-- Las tablas foráneas y "parametros" NO se conceden: solo se acceden vía funciones.
