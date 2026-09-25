<?php
/**
 * Siembra idempotente de contenido de ejemplo en Joomla (PostgreSQL).
 *
 * - Crea artículos publicados y destacados (aparecen en la portada) para que
 *   el portal sea navegable y genere tráfico/métricas reales (hits).
 * - Activa el registro de IP en el Action Log de Joomla, para que la IP del
 *   cliente reconstruida por mod_remoteip (X-Forwarded-For) quede en la BD.
 *
 * Se ejecuta en cada arranque del contenedor, pero solo inserta si el
 * contenido aún no existe.
 */

$cfgFile = '/var/www/html/configuration.php';
if (!is_file($cfgFile)) {
    fwrite(STDERR, "[seed] Joomla no está instalado todavía; se omite la siembra\n");
    exit(0);
}
require $cfgFile;
$cfg = new JConfig();
$p   = $cfg->dbprefix;

$conn = pg_connect(sprintf(
    "host=%s dbname=%s user=%s password=%s connect_timeout=10 application_name=joomla-seed",
    $cfg->host, $cfg->db, $cfg->user, $cfg->password
));
if (!$conn) {
    fwrite(STDERR, "[seed] No se pudo conectar a PostgreSQL\n");
    exit(1);
}
pg_set_client_encoding($conn, 'UTF8');

// 1) Registro de IP en el Action Log (com_actionlogs -> ip_logging = 1)
pg_query($conn, "UPDATE {$p}extensions
                 SET params = jsonb_set(COALESCE(NULLIF(params,''),'{}')::jsonb, '{ip_logging}', '1')::text
                 WHERE element = 'com_actionlogs' AND type = 'component'");

// 2) Artículos (idempotente por alias)
$existe = pg_query_params($conn, "SELECT 1 FROM {$p}content WHERE alias = $1", ['bienvenida-portal']);
if (pg_num_rows($existe) > 0) {
    fwrite(STDERR, "[seed] El contenido ya existe; nada que hacer\n");
    exit(0);
}

$autor = pg_fetch_result(pg_query($conn, "SELECT id FROM {$p}users ORDER BY id LIMIT 1"), 0, 0);
$stage = pg_fetch_result(pg_query($conn, "SELECT id FROM {$p}workflow_stages WHERE \"default\" = 1 ORDER BY id LIMIT 1"), 0, 0);
$catid = pg_fetch_result(pg_query($conn, "SELECT id FROM {$p}categories WHERE extension = 'com_content' AND alias = 'uncategorised' LIMIT 1"), 0, 0);

$articulos = [
    [
        'bienvenida-portal',
        'Bienvenido al portal del clúster de Comunicaciones',
        '<p>Este portal institucional corre en <strong>Joomla</strong> sobre <strong>PostgreSQL 16</strong> y se publica a través de un proxy inverso <strong>Nginx</strong>, único punto de entrada del clúster (TCP/80).</p>'
      . '<ul><li><a href="/jupyter/">JupyterLab</a>: análisis de datos del tráfico.</li>'
      . '<li><a href="/grafana/">Grafana</a>: tableros de monitoreo del tráfico y la actividad del CMS.</li></ul>',
        '<p>Cada visita a este sitio queda registrada por Nginx y por Apache, se expone en PostgreSQL mediante <em>file_fdw</em> y se grafica en Grafana en tiempo real. Navegue por los artículos para generar tráfico y observe cómo cambian los paneles.</p>',
    ],
    [
        'modelo-osi-en-contenedores',
        'Laboratorio de redes: el modelo OSI en contenedores',
        '<p>Una petición HTTP a este portal atraviesa las capas 7, 4, 3 y 2 del modelo OSI dentro del host Docker: cabeceras HTTP, conexiones TCP, direccionamiento IP en redes bridge y tramas Ethernet entre interfaces <code>veth</code>.</p>',
        '<p>Las redes <code>frontend_net</code> y <code>backend_net</code> son puentes Linux independientes. El DNS embebido de Docker (127.0.0.11) resuelve los nombres de servicio como <code>database</code> o <code>joomla</code>.</p>',
    ],
    [
        'proxy-inverso-nginx',
        'Proxy inverso con Nginx: cabeceras y WebSockets',
        '<p>Nginx enruta por prefijo: <code>/</code> hacia Joomla, <code>/jupyter/</code> hacia JupyterLab y <code>/grafana/</code> hacia Grafana, inyectando las cabeceras <code>Host</code>, <code>X-Forwarded-For</code> y <code>X-Forwarded-Proto</code>.</p>',
        '<p>Los kernels de Jupyter usan WebSockets, que requieren el mecanismo <code>HTTP/1.1 Upgrade</code>: Nginx reenvía las cabeceras <code>Upgrade</code> y <code>Connection: upgrade</code> para que la conexión TCP pase a transportar tramas WebSocket.</p>',
    ],
    [
        'postgresql-fuente-de-datos',
        'PostgreSQL como fuente de datos del clúster',
        '<p>PostgreSQL es el motor de persistencia del CMS y, a la vez, la fuente de datos de Grafana y Jupyter. Solo es accesible desde la red interna <code>backend_net</code> en el puerto TCP 5432.</p>',
        '<p>Grafana y Jupyter se conectan con usuarios de solo lectura que únicamente ven el esquema <code>monitoreo</code>, aplicando el principio de mínimo privilegio.</p>',
    ],
    [
        'segmentacion-de-redes',
        'Segmentación de redes: frontend_net y backend_net',
        '<p>La red <code>backend_net</code> se declaró como <em>internal</em>: no tiene gateway ni reglas NAT hacia el exterior, por lo que la base de datos no tiene visibilidad de la red externa.</p>',
        '<p>Los contenedores que necesitan hablar con la base de datos (Joomla, Grafana y Jupyter) tienen dos interfaces, una en cada puente; Nginx solo vive en <code>frontend_net</code>.</p>',
    ],
    [
        'monitoreo-con-grafana',
        'Monitoreo del tráfico con Grafana',
        '<p>El tablero aprovisionado muestra peticiones por código HTTP, IPs recurrentes, rutas más solicitadas, latencias y reutilización de conexiones keep-alive.</p>',
        '<p>Todo se configura de forma declarativa en <code>/etc/grafana/provisioning</code>: no es necesario crear datasources ni dashboards a mano.</p>',
    ],
];

pg_query($conn, 'BEGIN');
$orden = 1;
foreach ($articulos as [$alias, $titulo, $intro, $full]) {
    $res = pg_query_params($conn,
        "INSERT INTO {$p}content
            (asset_id, title, alias, introtext, \"fulltext\", state, catid, created, created_by,
             modified, modified_by, publish_up, images, urls, attribs, version, ordering,
             metakey, metadesc, access, hits, metadata, featured, language, note)
         VALUES (0, $1, $2, $3, $4, 1, $5, now() AT TIME ZONE 'UTC', $6,
                 now() AT TIME ZONE 'UTC', $6, now() AT TIME ZONE 'UTC', '{}', '{}', '{}', 1, $7,
                 '', '', 1, 0, '{}', 1, '*', '')
         RETURNING id",
        [$titulo, $alias, $intro, $full, $catid, $autor, $orden]);
    $id = pg_fetch_result($res, 0, 0);
    pg_query_params($conn, "INSERT INTO {$p}content_frontpage (content_id, ordering) VALUES ($1, $2)", [$id, $orden]);
    pg_query_params($conn, "INSERT INTO {$p}workflow_associations (item_id, stage_id, extension) VALUES ($1, $2, 'com_content.article')", [$id, $stage]);
    $orden++;
}
pg_query($conn, 'COMMIT');

fwrite(STDERR, "[seed] " . count($articulos) . " artículos creados\n");
