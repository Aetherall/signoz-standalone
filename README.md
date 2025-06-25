# 🚀 SigNoz Standalone - All-in-One Container

A completely self-contained SigNoz deployment in a single Docker container. This image bundles ClickHouse, ZooKeeper, SigNoz, and OpenTelemetry Collector - no external dependencies required.

> ⚠️ **WARNING**: This is designed for local development, testing, and evaluation purposes only. **NOT SUITABLE FOR PRODUCTION USE!** For production deployments, please use the [official SigNoz Helm charts](https://github.com/SigNoz/charts) or [Docker Compose setup](https://github.com/SigNoz/signoz/tree/develop/deploy).

## ✨ Features

- 📦 **Single Container**: Everything runs in one container for maximum simplicity
- 🔧 **No External Dependencies**: Includes ClickHouse, ZooKeeper, SigNoz, and OTEL Collector
- 🏗️ **Official Components**: Uses official SigNoz components
- 💻 **Multi-Architecture Support**: Supports both AMD64 and ARM64
- 🔐 **Configurable Admin Credentials**: Set your own admin email/password via environment variables
- 💾 **Persistent Storage**: Data persists across container restarts using Docker volumes

## 🚀 Quick Start

### 🐳 Using Docker Compose (Recommended)

```bash
# Download the example compose file
wget https://raw.githubusercontent.com/Aetherall/signoz-standalone/main/docker-compose.example.yml -O docker-compose.yml

# Start SigNoz
docker compose up -d

# Access SigNoz UI at http://localhost:9999
```

### 🏃 Using Docker Run

```bash
docker run -d \
  --name signoz \
  -p 9999:8080 \
  -p 4317:4317 \
  -p 4318:4318 \
  -v signoz_db_telemetry:/var/lib/clickhouse \
  -v signoz_db_application:/var/lib/signoz \
  -e SIGNOZ_ADMIN_EMAIL=admin@signoz.local \
  -e SIGNOZ_ADMIN_PASSWORD=admin123 \
  ghcr.io/aetherall/signoz-standalone:latest
```

## ⚙️ Configuration

### 🔧 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIGNOZ_ADMIN_EMAIL` | `admin@signoz.local` | Admin user email |
| `SIGNOZ_ADMIN_PASSWORD` | `admin123` | Admin user password |
| `SIGNOZ_ADMIN_NAME` | `Admin` | Admin user display name |
| `SIGNOZ_TELEMETRY_ENABLED` | `false` | Enable/disable SigNoz telemetry |

### 🔌 Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8080 | HTTP | SigNoz UI (mapped to 9999 in examples) |
| 4317 | gRPC | OTLP gRPC receiver |
| 4318 | HTTP | OTLP HTTP receiver |

### 💾 Volumes

| Volume Path | Description |
|-------------|-------------|
| `/var/lib/clickhouse` | ClickHouse data storage |
| `/var/lib/signoz` | SigNoz application data |

## 📡 Sending Telemetry Data

### 🛠️ OpenTelemetry SDK Configuration

Configure your applications to send telemetry data to:
- **OTLP gRPC**: `localhost:4317`
- **OTLP HTTP**: `localhost:4318`

## 🔨 Building

```bash
# Clone the repository
git clone https://github.com/Aetherall/signoz-standalone.git
cd signoz-standalone

# Build the image
docker build -t signoz-standalone:local .

# Run with docker-compose
docker compose up -d
```

## 🏗️ Architecture

This container runs multiple services managed by Supervisor:

1. **ZooKeeper**: Coordination service for ClickHouse
2. **ClickHouse**: Time-series database for telemetry storage
3. **Schema Migrator**: Initializes database schemas
4. **SigNoz**: Query service and UI
5. **OpenTelemetry Collector**: Receives and processes telemetry data

## 🙏 Acknowledgments

This project packages official SigNoz components into a single container for ease of deployment. All credit for SigNoz itself goes to the [SigNoz team](https://github.com/SigNoz/signoz).