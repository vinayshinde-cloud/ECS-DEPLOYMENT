FROM public.ecr.aws/docker/library/python:3.9.18
EXPOSE 80
WORKDIR /app
COPY requirements.txt ./requirements.txt
COPY Home.py ./Home.py
COPY components ./components
COPY pages ./pages
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_PROXY=* \
    HTTP_PROXY= \
    HTTPS_PROXY= \
    http_proxy= \
    https_proxy=
RUN unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY PIP_PROXY || true \
    && rm -f /etc/pip.conf /root/.pip/pip.conf /root/.config/pip/pip.conf || true \
    && printf "[global]\nindex-url = https://pypi.org/simple\n" > /etc/pip.conf \
    && pip3 install --no-cache-dir -r requirements.txt
CMD ["streamlit","run","Home.py","--server.headless","true","--server.port","80","--server.address=0.0.0.0","--server.enableCORS","false","--browser.gatherUsageStats","false"]