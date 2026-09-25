# Parcial 2 práctico: despliegue multi-contenedor, orquestación y modelo OSI

**Comunicaciones · Ingeniería Mecatrónica**

Clúster de 5 contenedores orquestado con Docker Compose:

| Servicio | Imagen | Rol |
|---|---|---|
| `nginx` | `nginx:1.31-alpine` | Proxy inverso, **único puerto publicado (80)**. Enruta `/`, `/jupyter/`, `/grafana/`. |
| `joomla` | `joomla:6.1.3-php8.4-apache` | Portal institucional (CMS) instalado de forma desatendida sobre PostgreSQL. |
| `database` | `postgres:16-alpine` | Motor relacional. Solo en `backend_net` (red interna, sin salida al exterior). |
| `jupyter` | `quay.io/jupyter/minimal-notebook:lab-4.6.3` + librerías | JupyterLab con el cuaderno `analisis_datos.ipynb` precargado. |
| `grafana` | `grafana/grafana:13.2.2` | Dashboards aprovisionados automáticamente (datasource PostgreSQL). |

El documento técnico completo (topología, mecanismo de logs y análisis OSI) está en **[INFORME.md](INFORME.md)**.

---

## Requisitos

* Docker Engine 24+ con el plugin **Docker Compose v2** (o Docker Desktop).
* Puerto **80** libre en el host (si está ocupado, cambie `HTTP_PORT` en `.env`).
* Conexión a Internet la primera vez (descarga de imágenes y construcción de la imagen de Jupyter).

## Arranque (un solo paso)

```bash
git clone <URL_DEL_REPOSITORIO>
cd parcial-redes-comunicaciones
cp .env.example .env
docker compose up -d
```

No hay que hacer nada más. El primer arranque tarda entre 1 y 3 minutos: se construye la imagen de Jupyter, se instala Joomla contra PostgreSQL y se siembran artículos de ejemplo. `docker compose up -d` espera a que cada dependencia esté **healthy** antes de arrancar la siguiente (`depends_on: condition: service_healthy`).

Para comprobar el estado:

```bash
docker compose ps
```

Los 5 servicios deben aparecer como `Up (healthy)`.

## Accesos

| Qué | URL | Credenciales (por defecto, en `.env.example`) |
|---|---|---|
| Portal Joomla | <http://localhost/> | Público |
| Administración de Joomla | <http://localhost/administrator/> | `admin` / `AdminJoomla_2026` |
| JupyterLab (abre el cuaderno directamente) | <http://localhost/jupyter/?token=parcial2026> | token `parcial2026` |
| Grafana (dashboard de inicio) | <http://localhost/grafana/> | Acceso anónimo de solo lectura. Admin: `admin` / `AdminGrafana_2026` |

PostgreSQL **no** se publica en el host. Para inspeccionarlo:

```bash
docker compose exec database psql -U dba_admin -d joomla
```

## Demostración rápida

1. Abra <http://localhost/> y navegue por los artículos (use también una URL inexistente para generar un 404).
2. Abra <http://localhost/grafana/>. El dashboard **"Parcial Comunicaciones - Tráfico Joomla y PostgreSQL"** se refresca cada 10 s y muestra las peticiones por código HTTP, las IPs recurrentes, las rutas, la latencia, la reutilización keep-alive, la actividad de Joomla y las conexiones a PostgreSQL.
3. Abra <http://localhost/jupyter/?token=parcial2026> y ejecute **Run → Run All Cells**. El cuaderno consulta PostgreSQL con `psycopg2`/SQLAlchemy, genera tráfico e inicia sesión en Joomla, grafica los logs y muestra DNS, rutas y ARP.

La guía detallada paso a paso está en la sección 3 de [INFORME.md](INFORME.md#sección-3-guía-de-verificación-y-demostración).

## Estructura del repositorio

```
parcial-redes-comunicaciones/
├── docker-compose.yml          # Orquestación de los 5 servicios, 2 redes y 5 volúmenes
├── .env.example                # Variables/credenciales por defecto
├── README.md                   # Este archivo
├── INFORME.md                  # Documento técnico (topología + modelo OSI + verificación)
├── nginx/
│   └── default.conf            # Proxy inverso, WebSockets, keep-alive, log TSV
├── joomla/
│   ├── joomla-start.sh         # Envoltorio del entrypoint: instala, siembra, arranca Apache
│   ├── seed_contenido.php      # Artículos de ejemplo (idempotente)
│   └── apache-logging.conf     # Log de Apache exportado a volumen + ServerName
├── database/
│   └── init/
│       ├── 01-roles.sh         # Roles con mínimo privilegio
│       └── 02-monitoreo.sql    # file_fdw + vistas del esquema "monitoreo"
├── jupyter/
│   ├── Dockerfile              # minimal-notebook + psycopg2, SQLAlchemy, pandas, matplotlib
│   ├── jupyter_server_config.py
│   └── notebooks/
│       └── analisis_datos.ipynb
├── grafana/
│   └── provisioning/
│       ├── datasources/datasource.yml
│       └── dashboards/
│           ├── dashboard.yml
│           └── joomla_logs.json
└── docs/
    ├── img/                    # Diagrama de arquitectura y capturas del informe
    ├── evidencias/             # Salidas reales (redes, DNS, NAT, tcpdump, WebSocket...)
    └── recolectar_evidencias.ps1  # Regenera docs/evidencias con el stack arriba
```

## Operación

```bash
docker compose logs -f nginx          # ver logs de un servicio
docker compose down                   # detener (conserva los datos)
docker compose down -v                # detener y borrar volúmenes (reinicio limpio)
```

### Problemas frecuentes

* **Puerto 80 ocupado**: ponga `HTTP_PORT=8080` en `.env` y use `http://localhost:8080/`.
* **`Pool overlaps with other one on this address space`**: otra red de Docker usa `10.201.10.0/24` o `10.201.20.0/24`. Cambie `FRONTEND_SUBNET` y `BACKEND_SUBNET` en `.env`.
* **Jupyter no deja guardar el cuaderno (Linux)**: el contenedor corre con UID 1000. Si su usuario tiene otro UID, ejecutar las celdas funciona igual; para poder guardar, use `chmod -R a+w jupyter/notebooks`.
