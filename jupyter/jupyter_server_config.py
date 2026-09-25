
# ---------------------------------------------------------------------
# Configuración añadida para el parcial (Jupyter detrás de Nginx)
# ---------------------------------------------------------------------
c = get_config()  # noqa: F821

# Nginx publica Jupyter bajo el prefijo /jupyter/ (sin reescribir la ruta)
c.ServerApp.base_url = "/jupyter/"

# Al entrar se abre directamente el cuaderno precargado
c.ServerApp.default_url = "/lab/tree/work/analisis_datos.ipynb"
# JupyterLab (ExtensionApp) tiene su propio default_url ("/lab"); se sobrescribe también
c.LabApp.default_url = "/lab/tree/work/analisis_datos.ipynb"

# Sin consultas a Internet por noticias/actualizaciones (despliegue desatendido)
c.LabApp.news_url = None
c.LabApp.check_for_updates_class = "jupyterlab.NeverCheckForUpdate"

# Confiar en X-Forwarded-For / X-Forwarded-Proto / X-Real-IP inyectadas por Nginx
c.ServerApp.trust_xheaders = True

# El token se toma de la variable de entorno JUPYTER_TOKEN (definida en .env)
# Escucha en todas las interfaces del contenedor (TCP/8888), sin publicarse al host
c.ServerApp.ip = "0.0.0.0"
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
