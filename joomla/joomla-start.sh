#!/bin/bash
# =====================================================================
#  Envoltorio del entrypoint oficial de la imagen joomla.
#
#  1) El entrypoint oficial solo ejecuta la instalación desatendida cuando el
#     primer argumento empieza por "apache2". Se invoca con "apache2ctl -v"
#     (comando inocuo que imprime la versión y termina) para que instale
#     Joomla contra PostgreSQL usando las variables JOOMLA_*.
#  2) Se siembra contenido de ejemplo (idempotente) para que el portal tenga
#     artículos navegables que generen tráfico y métricas (hits).
#  3) Se arranca Apache en primer plano con el mismo entrypoint oficial.
# =====================================================================
set -e

echo "[parcial] Paso 1/3: instalación desatendida de Joomla (si hace falta)"
/entrypoint.sh apache2ctl -v

echo "[parcial] Paso 2/3: siembra de contenido de ejemplo"
php /opt/parcial/seed_contenido.php || echo "[parcial] AVISO: la siembra de contenido falló (el portal funciona igual)"

echo "[parcial] Paso 3/3: arrancando Apache"
exec /entrypoint.sh apache2-foreground
