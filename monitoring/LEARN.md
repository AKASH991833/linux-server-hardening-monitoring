# Monitoring from zero

hk collects values. The exporter caches them every 30 seconds and serves /metrics. Prometheus stores samples and evaluates rules. Grafana draws charts. Alert rules appearing in Prometheus do not mean anyone receives a message: this demo has no Alertmanager receiver.

Run `docker compose -f monitoring/compose.yml up --build -d`. Open http://localhost:3000 (viewer), http://localhost:9090 and http://localhost:9108/metrics. Stop with `docker compose -f monitoring/compose.yml down`.

All published ports bind localhost. Do not expose anonymous Grafana or an unauthenticated exporter to the internet. For production, add TLS/auth at a reverse proxy and a real alert receiver. Images are version-pinned demo dependencies; review updates and vulnerabilities before production.

IMPORTANT: this container reports its own container-visible /proc, filesystems and logs, not full host health. Missing RAID/disk series are missing, not zero. Use the exporter on the actual host under a dedicated least-privileged service account for real host metrics; set HK_AUTH_LOG to a readable SSH log, and grant read access only to needed sources. The demo does not mount /, /dev or Docker socket and cannot administer the host.

`promtool check rules monitoring/alerts.yml` checks syntax. From monitoring run `promtool test rules alerts.test.yml` to test an alert firing and recovering against synthetic samples. Compose CI also verifies Prometheus sees the real exporter and Grafana loads the provisioned dashboard. Screenshots are from that running dashboard, not hand-drawn metrics.

Exercise: query hk_metric{name="mem"}; explain the % units. Explain why no disk: series in an overlay-only container is not a healthy disk verdict. Simulate samples only in the rule test file, never falsify live production data.
