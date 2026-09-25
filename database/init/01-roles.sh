#!/bin/bash
# =====================================================================
#  Inicialización de PostgreSQL (se ejecuta solo con el volumen vacío).
#  Crea los roles con el principio de mínimo privilegio:
#    - JOOMLA_DB_USER   : dueño de la base de datos del CMS (sin superusuario)
#    - lectores_monitoreo (grupo, NOLOGIN): solo lee el esquema "monitoreo"
#        * GRAFANA_DB_USER  : usado por el datasource aprovisionado de Grafana
#        * ANALISTA_DB_USER : usado por el cuaderno de Jupyter
# =====================================================================
set -euo pipefail

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v db="$POSTGRES_DB" \
     -v joomla_user="$JOOMLA_DB_USER"     -v joomla_pass="$JOOMLA_DB_PASSWORD" \
     -v grafana_user="$GRAFANA_DB_USER"   -v grafana_pass="$GRAFANA_DB_PASSWORD" \
     -v analista_user="$ANALISTA_DB_USER" -v analista_pass="$ANALISTA_DB_PASSWORD" \
     -v prefix="$JOOMLA_DB_PREFIX" <<'EOSQL'

-- Rol de aplicación del CMS: dueño de la BD (y por tanto del esquema public)
CREATE ROLE :"joomla_user" LOGIN PASSWORD :'joomla_pass';
ALTER DATABASE :"db" OWNER TO :"joomla_user";

-- Grupo de solo lectura y sus miembros
CREATE ROLE lectores_monitoreo NOLOGIN;
CREATE ROLE :"grafana_user"  LOGIN PASSWORD :'grafana_pass'  IN ROLE lectores_monitoreo;
CREATE ROLE :"analista_user" LOGIN PASSWORD :'analista_pass' IN ROLE lectores_monitoreo;

-- pg_monitor permite ver pg_stat_activity de todos los clientes (IPs/puertos
-- de las conexiones TCP), útil para el análisis de Capa 3/4. No da acceso a datos.
GRANT pg_monitor TO lectores_monitoreo;

-- Parámetro que usan las funciones de monitoreo para ubicar las tablas de Joomla
CREATE SCHEMA monitoreo;
CREATE TABLE monitoreo.parametros (clave text PRIMARY KEY, valor text NOT NULL);
INSERT INTO monitoreo.parametros VALUES ('joomla_prefix', :'prefix');
EOSQL
