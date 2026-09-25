# =====================================================================
#  JupyterLab para el parcial.
#  Base: jupyter/minimal-notebook (hoy publicada en quay.io; las imágenes de
#  Docker Hub "jupyter/*" dejaron de actualizarse en 2023). Etiqueta fijada
#  para que el despliegue sea reproducible.
#  Se añaden las librerías que usa el cuaderno (psycopg2, SQLAlchemy, pandas,
#  matplotlib) para que funcione sin instalar nada a mano.
# =====================================================================
FROM quay.io/jupyter/minimal-notebook:lab-4.6.3

RUN pip install --no-cache-dir \
        "psycopg2-binary==2.9.*" \
        "SQLAlchemy==2.0.*" \
        "pandas==2.3.*" \
        "matplotlib==3.10.*" \
        "requests==2.*" \
    && fix-permissions "${CONDA_DIR}" \
    && fix-permissions "/home/${NB_USER}" \
    && jupyter labextension disable "@jupyterlab/apputils-extension:announcements"

# Configuración del servidor para funcionar detrás del proxy inverso en /jupyter/
COPY jupyter_server_config.py /etc/jupyter/jupyter_server_config_parcial.py
RUN cat /etc/jupyter/jupyter_server_config_parcial.py >> /etc/jupyter/jupyter_server_config.py
