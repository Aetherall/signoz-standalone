# SigNoz Single Container - Standalone Version
# Completely self-contained with no external file dependencies
# Includes: ClickHouse + ZooKeeper + SigNoz + OTEL Collector in one container

FROM clickhouse/clickhouse-server:24.1.2-alpine AS clickhouse-base

FROM ubuntu:22.04

# Install dependencies including Java for ZooKeeper
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    supervisor \
    openjdk-11-jre-headless \
    sqlite3 \
    uuid-runtime \
    apache2-utils \
    && rm -rf /var/lib/apt/lists/*

# Download and install ZooKeeper
RUN wget -O /tmp/zookeeper.tar.gz "https://dlcdn.apache.org/zookeeper/zookeeper-3.7.2/apache-zookeeper-3.7.2-bin.tar.gz" \
    && tar -xzf /tmp/zookeeper.tar.gz -C /opt \
    && mv /opt/apache-zookeeper-3.7.2-bin /opt/zookeeper \
    && rm /tmp/zookeeper.tar.gz

# Copy ClickHouse binaries and configs from official image
COPY --from=clickhouse-base /usr/bin/clickhouse* /usr/bin/
COPY --from=clickhouse-base /etc/clickhouse-server /etc/clickhouse-server/
COPY --from=clickhouse-base /etc/clickhouse-client /etc/clickhouse-client/

# Create clickhouse user (Alpine image uses different user setup)
RUN groupadd -r clickhouse && useradd -r -g clickhouse clickhouse

# Create ClickHouse users configuration with default SigNoz user
COPY <<EOF /etc/clickhouse-server/users.xml
<?xml version="1.0"?>
<clickhouse>
    <!-- Profiles of settings -->
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
            <load_balancing>random</load_balancing>
        </default>
        <readonly>
            <readonly>1</readonly>
        </readonly>
    </profiles>

    <!-- Users and ACL -->
    <users>
        <!-- Default user with no password for local development -->
        <default>
            <password></password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>

        <!-- SigNoz user for explicit authentication if needed -->
        <signoz>
            <password>signoz123</password>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </signoz>

        <!-- Admin user with stronger password for production-like testing -->
        <admin>
            <password_sha256_hex>240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9</password_sha256_hex>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </admin>
    </users>

    <!-- Quotas -->
    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>
</clickhouse>
EOF

# Copy binaries and assets from official Docker images
COPY --from=signoz/signoz-otel-collector:v0.111.42 /signoz-otel-collector /usr/local/bin/otelcol-signoz
COPY --from=signoz/signoz:v0.87.0 /root/signoz /usr/local/bin/signoz
COPY --from=signoz/signoz:v0.87.0 /etc/signoz /etc/signoz
COPY --from=signoz/signoz-schema-migrator:v0.111.42 /signoz-schema-migrator /usr/local/bin/schema-migrator

# Make binaries executable
RUN chmod +x /usr/local/bin/otelcol-signoz /usr/local/bin/signoz /usr/local/bin/schema-migrator

# Download histogram quantile binary for ClickHouse
RUN mkdir -p /var/lib/clickhouse/user_scripts \
    && wget -O /tmp/histogram-quantile.tar.gz "https://github.com/SigNoz/signoz/releases/download/histogram-quantile%2Fv0.0.1/histogram-quantile_linux_amd64.tar.gz" \
    && tar -xzf /tmp/histogram-quantile.tar.gz -C /tmp \
    && mv /tmp/histogram-quantile /var/lib/clickhouse/user_scripts/histogramQuantile \
    && chmod +x /var/lib/clickhouse/user_scripts/histogramQuantile \
    && rm /tmp/histogram-quantile.tar.gz

# Create necessary directories
RUN mkdir -p \
    /var/lib/clickhouse \
    /var/log/clickhouse-server \
    /opt/signoz/config \
    /opt/signoz/dashboards \
    /var/lib/signoz \
    /opt/zookeeper/data \
    /opt/zookeeper/logs

# Create ZooKeeper configuration
COPY <<EOF /opt/zookeeper/conf/zoo.cfg
tickTime=2000
dataDir=/opt/zookeeper/data
clientPort=2181
initLimit=10
syncLimit=5
maxClientCnxns=0
admin.enableServer=false
EOF

# Create single-node cluster configuration with ZooKeeper
COPY <<EOF /etc/clickhouse-server/config.d/cluster.xml
<?xml version="1.0"?>
<clickhouse>
    <zookeeper>
        <node index="1">
            <host>localhost</host>
            <port>2181</port>
        </node>
    </zookeeper>
    <remote_servers>
        <cluster>
            <shard>
                <replica>
                    <host>localhost</host>
                    <port>9000</port>
                </replica>
            </shard>
        </cluster>
    </remote_servers>
</clickhouse>
EOF

# Enable user-defined functions in ClickHouse
COPY <<EOF /etc/clickhouse-server/config.d/user_defined_functions.xml
<?xml version="1.0"?>
<clickhouse>
    <user_defined_executable_functions_config>*_function.xml</user_defined_executable_functions_config>
    <user_scripts_path>/var/lib/clickhouse/user_scripts</user_scripts_path>
    <user_defined_executable_functions_config>/etc/clickhouse-server/functions/*.xml</user_defined_executable_functions_config>
</clickhouse>
EOF

# Create histogram quantile function configuration
RUN mkdir -p /etc/clickhouse-server/functions
COPY <<EOF /etc/clickhouse-server/functions/histogram_quantile_function.xml
<functions>
    <function>
        <type>executable</type>
        <name>histogramQuantile</name>
        <return_type>Float64</return_type>
        <argument>
            <type>Array(Float64)</type>
            <name>buckets</name>
        </argument>
        <argument>
            <type>Array(Float64)</type>
            <name>values</name>
        </argument>
        <argument>
            <type>Float64</type>
            <name>phi</name>
        </argument>
        <format>TabSeparated</format>
        <command>/var/lib/clickhouse/user_scripts/histogramQuantile</command>
        <implicit_arguments/>
    </function>
</functions>
EOF

# OTEL Collector configuration with self-monitoring enabled
COPY <<EOF /opt/signoz/config/otel-collector-config-with-telemetry.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  prometheus:
    config:
      global:
        scrape_interval: 60s
      scrape_configs:
        - job_name: otel-collector
          static_configs:
          - targets:
              - localhost:8888
            labels:
              job_name: otel-collector

processors:
  batch:
    send_batch_size: 10000
    send_batch_max_size: 11000
    timeout: 10s
  resourcedetection:
    detectors: [env, system]
    timeout: 2s
  signozspanmetrics/delta:
    metrics_exporter: clickhousemetricswrite, signozclickhousemetrics
    metrics_flush_interval: 60s
    latency_histogram_buckets: [100us, 1ms, 2ms, 6ms, 10ms, 50ms, 100ms, 250ms, 500ms, 1000ms, 1400ms, 2000ms, 5s, 10s, 20s, 40s, 60s ]
    dimensions_cache_size: 100000
    aggregation_temporality: AGGREGATION_TEMPORALITY_DELTA
    enable_exp_histogram: true
    dimensions:
      - name: service.namespace
        default: default
      - name: deployment.environment
        default: default
      - name: signoz.collector.id
      - name: service.version

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  pprof:
    endpoint: 0.0.0.0:1777

exporters:
  clickhousetraces:
    datasource: tcp://127.0.0.1:9000/signoz_traces
    low_cardinal_exception_grouping: false
    use_new_schema: true
  clickhousemetricswrite:
    endpoint: tcp://127.0.0.1:9000/signoz_metrics
    disable_v2: true
    resource_to_telemetry_conversion:
      enabled: true
  clickhousemetricswrite/prometheus:
    endpoint: tcp://127.0.0.1:9000/signoz_metrics
    disable_v2: true
  signozclickhousemetrics:
    dsn: tcp://127.0.0.1:9000/signoz_metrics
  clickhouselogsexporter:
    dsn: tcp://127.0.0.1:9000/signoz_logs
    timeout: 10s
    use_new_schema: true

service:
  telemetry:
    logs:
      encoding: json
    metrics:
      address: 0.0.0.0:8888
  extensions:
    - health_check
    - pprof
  pipelines:
    traces:
      receivers: [otlp]
      processors: [signozspanmetrics/delta, batch]
      exporters: [clickhousetraces]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousemetricswrite, signozclickhousemetrics]
    metrics/prometheus:
      receivers: [prometheus]
      processors: [batch]
      exporters: [clickhousemetricswrite/prometheus, signozclickhousemetrics]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouselogsexporter]
EOF

# OTEL Collector configuration without self-monitoring
COPY <<EOF /opt/signoz/config/otel-collector-config-no-telemetry.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    send_batch_size: 10000
    send_batch_max_size: 11000
    timeout: 10s
  resourcedetection:
    detectors: [env, system]
    timeout: 2s
  signozspanmetrics/delta:
    metrics_exporter: clickhousemetricswrite, signozclickhousemetrics
    metrics_flush_interval: 60s
    latency_histogram_buckets: [100us, 1ms, 2ms, 6ms, 10ms, 50ms, 100ms, 250ms, 500ms, 1000ms, 1400ms, 2000ms, 5s, 10s, 20s, 40s, 60s ]
    dimensions_cache_size: 100000
    aggregation_temporality: AGGREGATION_TEMPORALITY_DELTA
    enable_exp_histogram: true
    dimensions:
      - name: service.namespace
        default: default
      - name: deployment.environment
        default: default
      - name: signoz.collector.id
      - name: service.version

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

exporters:
  clickhousetraces:
    datasource: tcp://127.0.0.1:9000/signoz_traces
    low_cardinal_exception_grouping: false
    use_new_schema: true
  clickhousemetricswrite:
    endpoint: tcp://127.0.0.1:9000/signoz_metrics
    disable_v2: true
    resource_to_telemetry_conversion:
      enabled: true
  signozclickhousemetrics:
    dsn: tcp://127.0.0.1:9000/signoz_metrics
  clickhouselogsexporter:
    dsn: tcp://127.0.0.1:9000/signoz_logs
    timeout: 10s
    use_new_schema: true

service:
  telemetry:
    logs:
      encoding: json
    metrics:
      level: none
  extensions:
    - health_check
  pipelines:
    traces:
      receivers: [otlp]
      processors: [signozspanmetrics/delta, batch]
      exporters: [clickhousetraces]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousemetricswrite, signozclickhousemetrics]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouselogsexporter]
EOF

# Prometheus configuration for SigNoz
COPY <<EOF /opt/signoz/config/prometheus.yml
global:
  scrape_interval: 5s
  evaluation_interval: 15s

alerting:
  alertmanagers:
  - static_configs:
    - targets: []

rule_files: []
scrape_configs: []

remote_read:
  - url: tcp://127.0.0.1:9000/signoz_metrics
EOF

# Create wait-for-clickhouse script inline
COPY <<'EOF' /opt/signoz/wait-for-clickhouse.sh
#!/bin/bash
# Wait for ClickHouse to be ready

set -e

echo "Waiting for ClickHouse to be ready..."

# Wait up to 60 seconds for ClickHouse to start
timeout=60
while [ $timeout -gt 0 ]; do
    if clickhouse-client --host 127.0.0.1 --port 9000 --query "SELECT 1" > /dev/null 2>&1; then
        echo "ClickHouse is ready!"
        break
    fi
    echo "Waiting for ClickHouse... ($timeout seconds remaining)"
    sleep 2
    timeout=$((timeout - 2))
done

if [ $timeout -le 0 ]; then
    echo "ERROR: ClickHouse failed to start within 60 seconds"
    exit 1
fi

# Test if histogramQuantile function is available
echo "Testing histogramQuantile function..."
if clickhouse-client --host 127.0.0.1 --port 9000 --query "SELECT histogramQuantile([1.0, 2.0], [10.0, 20.0], 0.9)" > /dev/null 2>&1; then
    echo "histogramQuantile function is ready!"
else
    echo "WARNING: histogramQuantile function is not available yet"
fi

echo "Running: $@"
exec "$@"
EOF

# Make the wait script executable
RUN chmod +x /opt/signoz/wait-for-clickhouse.sh

# Create OTEL config selector script
COPY <<'EOF' /opt/signoz/select-otel-config.sh
#!/bin/bash
# Select appropriate OTEL collector config based on SIGNOZ_TELEMETRY_ENABLED

if [ "${SIGNOZ_TELEMETRY_ENABLED}" = "true" ]; then
    echo "Self-monitoring ENABLED - using config with telemetry"
    cp /opt/signoz/config/otel-collector-config-with-telemetry.yaml /opt/signoz/config/otel-collector-config.yaml
else
    echo "Self-monitoring DISABLED - using config without telemetry"
    cp /opt/signoz/config/otel-collector-config-no-telemetry.yaml /opt/signoz/config/otel-collector-config.yaml
fi
EOF

RUN chmod +x /opt/signoz/select-otel-config.sh

# Create script to pre-populate default user
COPY <<'EOF' /opt/signoz/create-default-user.sh
#!/bin/bash
# Create default user in SigNoz SQLite database with configurable credentials

set -e

SIGNOZ_DB="/var/lib/signoz/signoz.db"

# Use environment variables or defaults
DEFAULT_EMAIL="${SIGNOZ_ADMIN_EMAIL:-admin@signoz.local}"
DEFAULT_PASSWORD="${SIGNOZ_ADMIN_PASSWORD:-admin123}"
DEFAULT_NAME="${SIGNOZ_ADMIN_NAME:-Admin}"

# Check if database exists and has users
if [ -f "$SIGNOZ_DB" ]; then
    USER_COUNT=$(sqlite3 "$SIGNOZ_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
    if [ "$USER_COUNT" -gt 0 ]; then
        echo "Users already exist in database, skipping default user creation"
        exit 0
    fi
fi

echo "Creating default organization and user..."
echo "Email: $DEFAULT_EMAIL"
echo "Name: $DEFAULT_NAME"

# Generate UUIDs for organization and user
ORG_ID=$(uuidgen)
USER_ID=$(uuidgen)
PASSWORD_ID=$(uuidgen)

# Generate bcrypt hash for the password dynamically
HASHED_PASSWORD=$(htpasswd -bnBC 10 "" "$DEFAULT_PASSWORD" | cut -d: -f2)
echo "Generated password hash: $HASHED_PASSWORD"

# Get current timestamp
TIMESTAMP=$(date +%s)

# Wait for SigNoz to be ready and create its tables
echo "Waiting for SigNoz to initialize database tables..."
for i in {1..60}; do
    if [ -f "$SIGNOZ_DB" ] && sqlite3 "$SIGNOZ_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='organizations';" | grep -q "organizations"; then
        echo "SigNoz database tables are ready!"
        break
    fi
    echo "Waiting for SigNoz database initialization... ($i/60)"
    sleep 2
done

# Insert default data into existing tables
sqlite3 "$SIGNOZ_DB" <<SQL
-- Insert default organization
INSERT OR IGNORE INTO organizations (id, created_at, updated_at, name, alias, key, display_name)
VALUES ('$ORG_ID', $TIMESTAMP, $TIMESTAMP, 'default', '', 12345, 'Default Organization');

-- Insert default admin user
INSERT OR IGNORE INTO users (id, created_at, updated_at, display_name, email, role, org_id)
VALUES ('$USER_ID', $TIMESTAMP, $TIMESTAMP, '$DEFAULT_NAME', '$DEFAULT_EMAIL', 'ADMIN', '$ORG_ID');

-- Insert password for admin user
INSERT OR IGNORE INTO factor_password (id, created_at, updated_at, password, temporary, user_id)
VALUES ('$PASSWORD_ID', $TIMESTAMP, $TIMESTAMP, '$HASHED_PASSWORD', 0, '$USER_ID');
SQL

echo "Default user created successfully!"
echo "Login with: $DEFAULT_EMAIL / $DEFAULT_PASSWORD"
EOF

RUN chmod +x /opt/signoz/create-default-user.sh

# Supervisor configuration
COPY <<EOF /etc/supervisor/conf.d/signoz.conf
[supervisord]
nodaemon=true
logfile=/dev/stdout
logfile_maxbytes=0
loglevel=info
pidfile=/var/run/supervisord.pid

[unix_http_server]
file=/var/run/supervisor.sock

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[program:zookeeper]
command=/opt/zookeeper/bin/zkServer.sh start-foreground
autostart=true
autorestart=true
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=90
environment=JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"

[program:clickhouse]
command=/usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml
autostart=true
autorestart=true
user=clickhouse
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=100

[program:schema-migrator-sync]
command=/opt/signoz/wait-for-clickhouse.sh /usr/local/bin/schema-migrator sync --dsn=tcp://127.0.0.1:9000 --up=
autostart=true
autorestart=false
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=150
startsecs=0
startretries=3

[program:schema-migrator-async]
command=/opt/signoz/wait-for-clickhouse.sh /usr/local/bin/schema-migrator async --dsn=tcp://127.0.0.1:9000 --up=
autostart=true
autorestart=false
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=160
startsecs=0
startretries=3

[program:create-default-user]
command=/opt/signoz/create-default-user.sh
autostart=true
autorestart=false
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=250
startsecs=0
startretries=1

[program:signoz]
command=/usr/local/bin/signoz --config=/opt/signoz/config/prometheus.yml
autostart=true
autorestart=true
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=200
environment=SIGNOZ_ALERTMANAGER_PROVIDER="signoz",SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN="tcp://127.0.0.1:9000",SIGNOZ_SQLSTORE_SQLITE_PATH="/var/lib/signoz/signoz.db",STORAGE="clickhouse",GODEBUG="netdns=go",TELEMETRY_ENABLED="%(ENV_SIGNOZ_TELEMETRY_ENABLED)s",DEPLOYMENT_TYPE="docker-single"

[program:select-otel-config]
command=/opt/signoz/select-otel-config.sh
autostart=true
autorestart=false
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=280
startsecs=0
startretries=1

[program:otelcol]
command=/usr/local/bin/otelcol-signoz --config=/opt/signoz/config/otel-collector-config.yaml
autostart=true
autorestart=true
user=root
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=300
environment=OTEL_RESOURCE_ATTRIBUTES="host.name=signoz-single,os.type=linux",LOW_CARDINAL_EXCEPTION_GROUPING="false"
EOF

# Set permissions
RUN chown -R clickhouse:clickhouse /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server \
    && chmod +x /var/lib/clickhouse/user_scripts/histogramQuantile \
    && chown -R root:root /opt/signoz /var/lib/signoz

# Environment variables for configuration
ENV SIGNOZ_ADMIN_EMAIL=admin@signoz.local
ENV SIGNOZ_ADMIN_PASSWORD=admin123
ENV SIGNOZ_ADMIN_NAME=Admin
ENV SIGNOZ_TELEMETRY_ENABLED=false

# Expose ports
EXPOSE 8080 4317 4318 8123 9000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/signoz.conf"]