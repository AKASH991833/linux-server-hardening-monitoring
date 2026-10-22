FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends bash coreutils findutils procps gawk sed grep util-linux hostname python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/hk
COPY hk ./
COPY lib ./lib
COPY checks ./checks
COPY config ./config
COPY monitoring/exporter.py ./monitoring/exporter.py
ENV HK_STATE=/tmp/hk-state HK_ALERT_CHANNELS=log
USER 65534:65534
EXPOSE 9108
CMD ["python3", "monitoring/exporter.py"]
