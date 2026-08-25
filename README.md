# MoodleKit Docker 🚀

**Production-Grade, 1-Click Multi-Tenant Moodle Cloud Stack** powered by Docker, Caddy, MariaDB, and Redis.

Designed for high-traffic academies, university clusters, and multi-domain LMS hosting with complete resource separation, automated SSL, isolated background cron workers, web-based plugin installation support, and 1-click disaster recovery.

---

## 🏗️ Architecture Overview

```
                          [ Incoming HTTPS Traffic ]
                                      │
                                      ▼
             ┌──────────────────────────────────────────────────┐
             │                Caddy Web Server                  │
             │   - Automatic Let's Encrypt / ZeroSSL TLS        │
             │   - Multi-Domain Dynamic Routing (sites.d/*.caddy)│
             │   - Internal X-Accel-Redirect (Moodledata Guard) │
             │   - Gzip & Zstandard Fast Edge Compression       │
             └────────┬────────────────────────────────┬────────┘
                      │                                │
        Domain A      │                  Domain B      │
        (e.g. academy.org)               (e.g. school.net)
                      ▼                                ▼
     ┌────────────────────────────────┐ ┌────────────────────────────────┐
     │   Tenant A: moodle-app-acad    │ │   Tenant B: moodle-app-sch     │
     │   - PHP 8.3 FPM (OPcache JIT)  │ │   - PHP 8.3 FPM (OPcache JIT)  │
     │   - Writable Plugin Subtrees   │ │   - Writable Plugin Subtrees   │
     │   - Moodle 5.2 (public/ router)│ │   - Moodle 4.5 (LTS Classic)   │
     └────────────────┬───────────────┘ └────────────────┬───────────────┘
                      │                                  │
     ┌────────────────┴───────────────┐ ┌────────────────┴───────────────┐
     │  Tenant A Cron Worker (acad)   │ │  Tenant B Cron Worker (sch)    │
     │  - Dedicated background daemon │ │  - Dedicated background daemon │
     │  - Non-blocking 1m task queue  │ │  - Non-blocking 1m task queue  │
     └────────────────┬───────────────┘ └────────────────┬───────────────┘
                      │                                  │
                      └────────────────┬─────────────────┘
                                       │
                      ┌────────────────┴────────────────┐
                      │                                 │
                      ▼                                 ▼
       ┌──────────────────────────────┐  ┌──────────────────────────────┐
       │   Shared MariaDB 11.4 Engine │  │      Shared Redis 7 Cache    │
       │   - Isolated DB per tenant   │  │   - MUC Application Cache    │
       │   - Dedicated credentials    │  │   - Redis Session Storage    │
       │   - Tuned InnoDB Buffer Pool │  │   - Tenant Key Prefixing     │
       └──────────────────────────────┘  └──────────────────────────────┘
```

---

## 🌟 Key Features & Engineering Highlights

| Feature | Description |
| :--- | :--- |
| 🏢 **Multi-Tenant & Multi-Domain** | Host unlimited Moodle tenants on unique domains (`learn.company.com`, `academy.org`) with zero friction. |
| 🔒 **Automatic SSL via Caddy** | Caddy handles automated Let's Encrypt / ZeroSSL TLS certificates and HTTP-to-HTTPS redirection dynamically. |
| ⚡ **Server Load Separation** | Interactive web requests (PHP-FPM) are completely separated from heavy background cron tasks (dedicated background worker container). Cron never slows down student quizzes or grading! |
| 🛡️ **Non-Executable `moodledata`** | Dataroot is placed outside the web document root and protected by Caddy internal `X-Accel-Redirect` / `X-Sendfile`. Direct HTTP access is blocked (403 Forbidden). |
| 🔌 **1-Click Web Plugin Installer** | Plugin directories (`mod`, `blocks`, `theme`, `local`, `auth`, `enrol`, etc.) are owned by `www-data` with proper permissions so administrators can install and update plugins directly from the Moodle Web UI. |
| 🚀 **High-Performance Redis Engine** | Built-in Redis 7 container for high-speed sessions (`\core\session\redis`) and MUC (Moodle Universal Cache) with tenant isolation. |
| 🗄️ **One Shared DB, Site-Only Extensible** | Single tuned database server (MariaDB 11.4) hosting isolated databases and users per tenant. Adding a tenant requires zero DB restarts. |
| 💾 **Structured Persistence** | Clear directory layout for persistent code, moodledata, TLS certificates, database tables, and Redis snapshots. |
| 📦 **Atomic Backup & 1-Click Restore** | Streamed database dump + moodledata snapshot (excluding temporary caches) bundled with metadata into a single `.tar.gz` archive. |
| 🎛️ **RAM Auto-Tuning** | Dynamic hardware detection calculating optimal MariaDB buffer pool, Redis memory, and PHP-FPM worker limits. |

---

## 🚀 Quickstart: 1-Click Installation

### Option A: Interactive Wizard
```bash
./easy-install.py
```
Follow the interactive prompts to set your email, choose Moodle version (5.2 or 4.5), specify your domain, and provision your first tenant.

### Option B: Scripted 1-Click Command
```bash
./easy-install.py \
  --sitename academy.example.com \
  --slug academy \
  --email admin@example.com \
  --moodle-version 5.2 \
  --fullname "Global Learning Academy"
```

---

## 🛠️ CLI Management (`moodlekit-docker`)

The `moodlekit-docker` CLI tool provides full lifecycle control over your multi-tenant cluster:

### 1. Core Infrastructure
```bash
# Initialize core services (Caddy, MariaDB, Redis)
./moodlekit-docker init -e admin@example.com

# Check status of core stack and all tenant sites
./moodlekit-docker status

# Re-tune memory allocation based on server RAM (balanced | conservative | aggressive)
./moodlekit-docker tune --mode balanced
```

### 2. Tenant Site Management
```bash
# Create a new tenant site with custom domain
./moodlekit-docker site create myschool \
  --domain myschool.example.com \
  --moodle-version 5.2 \
  --fullname "My School LMS" \
  --admin-user admin \
  --admin-pass "SecretPass123!#"

# List all active tenant sites, domains, and health
./moodlekit-docker site list

# Execute any command inside a tenant container (as www-data)
./moodlekit-docker site exec myschool -- php /var/www/html/admin/cli/purge_caches.php

# Trigger immediate Moodle cron for a tenant
./moodlekit-docker site cron myschool

# Install a plugin via CLI URL or ZIP
./moodlekit-docker site plugin myschool install https://moodle.org/plugins/download.php/...

# Remove a tenant site (cleanly teardown containers, route, and DB)
./moodlekit-docker site remove myschool
```

### 3. Backup & Disaster Recovery
```bash
# Create an atomic backup archive of a tenant
./moodlekit-docker site backup myschool
# Output: backups/myschool/backup_myschool_YYYYMMDD_HHMMSS.tar.gz

# 1-Click restore into a new or existing tenant
./moodlekit-docker site restore newschool backups/myschool/backup_myschool_20260824_120000.tar.gz \
  --domain newschool.example.com
```

---

## 📂 Persistent Directory Structure

```
.
├── docker/
│   ├── Dockerfile                 # Production PHP 8.3 FPM image
│   ├── entrypoint.sh              # Application bootstrap & permission fixer
│   ├── cron-entrypoint.sh         # Dedicated background worker daemon
│   ├── compose.core.yml           # Core infra (Caddy, MariaDB, Redis)
│   ├── conf/
│   │   ├── caddy/
│   │   │   ├── Caddyfile          # Master reverse proxy configuration
│   │   │   ├── moodle_common.caddy# Reusable security & FastCGI snippet
│   │   │   └── sites.d/           # Dynamic per-tenant routes (*.caddy)
│   │   ├── mariadb/my.cnf         # Tuned InnoDB buffer pool & UTF8mb4
│   │   ├── php/                   # Tuned php.ini, opcache.ini, fpm-pool.conf
│   │   └── redis/redis.conf       # LRU eviction & AOF persistence
│   └── templates/                 # Production config.php and compose templates
├── data/
│   ├── caddy/                     # Automated SSL certificates & ACME state
│   ├── db/                        # Persistent MariaDB data directory
│   └── redis/                     # Persistent Redis snapshots
├── sites/
│   └── <tenant_slug>/
│       ├── code/                  # Moodle PHP codebase & installed plugins
│       ├── moodledata/            # Moodle files (filedir, trashdir)
│       ├── compose.yml            # Site-specific app + cron compose
│       └── meta.json              # Tenant metadata
├── backups/                       # Local compressed backup archives
├── moodlekit-docker.py            # Main Multi-Tenant Python Orchestrator
└── easy-install.py                # 1-Click Bootstrap Wizard
```

---

## 🔒 Security & Optimization Defaults

- **OPcache JIT**: Enabled (`opcache.jit=tracing`, `opcache.jit_buffer_size=64M`, `opcache.max_accelerated_files=20000`).
- **PHP Limits**: `memory_limit=512M`, `max_input_vars=10000`, `upload_max_filesize=512M`, `post_max_size=512M`.
- **Database**: MariaDB 11.4 with `utf8mb4_unicode_ci` collation, `innodb_file_per_table=1`, and transactional read threads.
- **Moodledata Guard**: Zero direct web access; internal file streaming handled by Caddy's `@dataroot` block and Moodle's `X-Accel-Redirect`.
- **Slash Arguments**: Native FastCGI `PATH_INFO` splitting supported for Moodle 4.x and Moodle 5.x `r.php` front controllers.

---

## 🧪 Testing

Run the built-in automated test suite:
```bash
python3 tests/test_docker_orchestrator.py
```
