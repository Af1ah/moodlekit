# MoodleKit Docker Complete Operations & Deployment Manual

A complete, production-grade guide to deploying, scaling, managing, and troubleshooting the MoodleKit multi-tenant Docker platform.

---

## Table of Contents
1. [Prerequisites & System Requirements](#1-prerequisites--system-requirements)
2. [Fresh Server Installation (Zero to Production)](#2-fresh-server-installation-zero-to-production)
3. [Creating & Managing Tenants](#3-creating--managing-tenants)
4. [Tenant Sizing & Dynamic Scaling](#4-tenant-sizing--dynamic-scaling)
5. [Hardware Auto-Tuning (16GB vs 32GB VPS)](#5-hardware-auto-tuning-16gb-vs-32gb-vps)
6. [Filesystem Security & Permissions](#6-filesystem-security--permissions)
7. [Backups, Restores & Site Migration](#7-backups-restores--site-migration)
8. [Plugin Management (Web UI & CLI)](#8-plugin-management-web-ui--cli)
9. [Debugging & Troubleshooting Guide](#9-debugging--troubleshooting-guide)
10. [CLI Command Reference Cheat Sheet](#10-cli-command-reference-cheat-sheet)

---

## 1. Prerequisites & System Requirements

### Operating System
- Ubuntu 22.04 LTS / 24.04 LTS, Debian 12, or AlmaLinux / RHEL 9.

### Minimum Hardware
- **Entry / Dev**: 2 vCPUs, 4GB–8GB RAM (1–3 small sites).
- **Standard Production**: 4 vCPUs, 16GB RAM (2 Big or 1 Big + 2 Medium sites, 500–700 active users).
- **High-Capacity Cluster**: 8 vCPUs, 32GB RAM (4 Big or 1 Enterprise + 2 Big sites, 1,200+ active users).

### Ports Required
- **Port 80 (HTTP)**: Inbound web traffic & ACME challenge.
- **Port 443 (HTTPS/QUIC)**: Encrypted web traffic (TLS / HTTP/2 / HTTP/3).

### Required Packages
```bash
sudo apt update && sudo apt install -y git curl docker.io docker-compose-v2 python3
sudo systemctl enable --now docker
```

---

## 2. Fresh Server Installation (Zero to Production)

### Step 1: Clone MoodleKit
```bash
git clone https://github.com/Af1ah/moodlekit.git /home/aflah/projects/moodlekit
cd /home/aflah/projects/moodlekit
```

### Step 2: Choose Your Installation Method

#### Method A: Interactive 1-Click Wizard (Recommended for Beginners)
```bash
python3 easy-install.py
```
*Follow the on-screen prompts to configure admin email, build the image, and provision your first site.*

#### Method B: Fast Scripted CLI Bootstrap
```bash
# 1. Bootstrap shared core stack (Caddy, MariaDB, Redis):
./moodlekit-docker.py init --email admin@yourdomain.com

# 2. Build the optimized PHP 8.3 FPM production container image:
./moodlekit-docker.py build

# 3. Auto-tune shared memory for your host's RAM (16GB or 32GB):
./moodlekit-docker.py tune

# 4. Check that core services are healthy:
./moodlekit-docker.py status
```

---

## 3. Creating & Managing Tenants

### A. Creating a Production Tenant (Public Domain with Auto-SSL)
1. Point your domain's DNS `A` or `AAAA` record to your server's public IP address (e.g. `academy.example.com` -> `198.51.100.10`).
2. Run the creation command:
```bash
./moodlekit-docker.py site create academy \
  --domain academy.example.com \
  --plan big \
  --moodle-version 5.2 \
  --admin-user admin \
  --admin-pass "SuperSecret123!#" \
  --admin-email admin@example.com \
  --fullname "My Academy LMS" \
  --shortname "Academy"
```
*Caddy will automatically provision a valid Let's Encrypt / ZeroSSL TLS certificate, create the MariaDB database, configure Redis sessions, and run the Moodle database installer.*

---

### B. Creating a Local Development Tenant (`.local` Domain)
```bash
./moodlekit-docker.py site create lms2 \
  --domain lms2.local \
  --plan medium \
  --moodle-version 5.2
```
To access locally, add to your host's `/etc/hosts`:
```text
127.0.0.1 lms2.local
```

---

### C. Tenant Operations

#### 1. List All Active Sites & Statuses:
```bash
./moodlekit-docker.py site list
```

#### 2. Trigger Moodle Cron Immediately for a Tenant:
```bash
./moodlekit-docker.py site cron lms2
```

#### 3. Run Commands Inside Tenant as `www-data`:
```bash
# Check Moodle version:
./moodlekit-docker.py site exec lms2 -- php /var/www/html/admin/cli/checks.php

# Purge caches:
./moodlekit-docker.py site exec lms2 -- php /var/www/html/admin/cli/purge_caches.php

# Open interactive bash:
./moodlekit-docker.py site exec lms2 -- bash
```

#### 4. Completely Remove a Tenant:
```bash
# Interactive confirmation:
./moodlekit-docker.py site remove lms2

# Force remove (scripts/CI):
./moodlekit-docker.py site remove lms2 -f
```

---

## 4. Tenant Sizing & Dynamic Scaling

MoodleKit provides 4 hardcoded, production-optimized sizing profiles:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                           Tenant Sizing Profiles Matrix                          │
├────────────┬─────────────┬──────────────┬──────────────┬───────────┬─────────────┤
│ Plan       │ Process Mode│ Max Workers  │ Container    │ Container │ Target      │
│ Name       │ (pm)        │ (Children)   │ RAM Limit    │ CPU Limit │ Capacity    │
├────────────┼─────────────┼──────────────┼──────────────┼───────────┼─────────────┤
│ small      │ ondemand    │ 15 workers   │ 1.5 GB       │ 1.0 Core  │ 10–50 users │
│ medium     │ dynamic     │ 35 workers   │ 3.0 GB       │ 2.0 Cores │ 50–150 users│
│ big        │ dynamic     │ 60 workers   │ 5.0 GB       │ 3.5 Cores │ 200–350 usrs│
│ enterprise │ dynamic     │ 120 workers  │ 10.0 GB      │ 6.0 Cores │ 400–700+ usrs│
└────────────┴─────────────┴──────────────┴──────────────┴───────────┴─────────────┘
```

### Inspect Sizing Profiles:
```bash
./moodlekit-docker.py site plans
```

### Live Dynamic Resizing (0 Downtime):
Upgrade or downgrade any tenant on the fly during exam spikes:
```bash
# Scale up to BIG plan before an exam:
./moodlekit-docker.py site resize lms2 --plan big

# Scale down to SMALL (ondemand, ~15MB idle RAM) after semester ends:
./moodlekit-docker.py site resize lms2 --plan small
```

---

## 5. Hardware Auto-Tuning (16GB vs 32GB VPS)

Run the hardware tuner to inspect your server's RAM and apply the optimal database and Redis memory configuration:
```bash
./moodlekit-docker.py tune
```

### Allocation Rules:
- **16GB Host**:
  - MariaDB Buffer Pool: `6,144 MB` (6.0 GB)
  - Redis Max Memory: `1,536 MB` (1.5 GB)
  - Worker Budget: 90–120 total workers (supports 2 Big or 1 Big + 2 Medium sites).
- **32GB Host**:
  - MariaDB Buffer Pool: `14,336 MB` (14.0 GB)
  - Redis Max Memory: `3,072 MB` (3.0 GB)
  - Worker Budget: 250–400 total workers (supports 4 Big or Enterprise sites).

---

## 6. Filesystem Security & Permissions

MoodleKit enforces strict separation of execution privileges across directories and files:

- **Dataroot (`/var/moodledata`)**:
  - Directories: `02775` (`drwxrwsr-x`) with `setgid` bit.
  - Files: `0664` (`-rw-rw-r--`) with **NO execute bit**.
  - Direct HTTP access is completely blocked by Caddy (`404/403`).
- **Core PHP Codebase (`/var/www/html`)**:
  - `config.php`: `0644` read-only (`preventexecpath = true`).
  - Core files: `0644` / `0755` read-only.
  - Plugin subtrees (`mod/`, `blocks/`, `theme/`, `local/`, `vendor/`): `2775` / `0664` writable by `www-data` in standard mode.

### Fix & Harden Permissions Anytime:
```bash
# Standard mode (web plugin installer allowed):
./moodlekit-docker.py site fix-perms lms2 --mode standard

# Strict mode (entire codebase 100% read-only, CLI deploys only):
./moodlekit-docker.py site fix-perms lms2 --mode strict
```

---

## 7. Backups, Restores & Site Migration

### A. Creating a Backup
Captures the SQL database, Moodle codebase, and `moodledata` (filtering out transient caches):
```bash
./moodlekit-docker.py site backup lms2
# Saved to: backups/backup_lms2_YYYYMMDD_HHMMSS.tar.gz
```

### B. Restoring to a New Tenant / Server
```bash
./moodlekit-docker.py site restore lms_restored backups/backup_lms2_20260825_120000.tar.gz \
  --domain restored.example.com \
  --plan big
```

---

## 8. Plugin Management (Web UI & CLI)

### Method 1: Web Interface
1. Log in as Moodle Administrator.
2. Go to **Site Administration → Plugins → Install plugins**.
3. Upload the ZIP archive and click **Install plugin from the ZIP file**.

### Method 2: Command Line (Frankenstyle Auto-Detection)
```bash
./moodlekit-docker.py site plugin lms2 install https://moodle.org/plugins/download.php/31245/mod_attendance_moodle52_2026010100.zip
```

---

## 9. Debugging & Troubleshooting Guide

### A. Check Cluster & Container Health
```bash
# Overview of all containers and tenants:
./moodlekit-docker.py status

# Live resource usage (CPU / Memory):
docker stats --no-stream
```

### B. Viewing Logs
```bash
# 1. Edge Proxy (Caddy access & SSL logs):
docker compose logs -f caddy

# 2. Database (MariaDB error logs):
docker compose logs -f db

# 3. Cache & Session Store (Redis logs):
docker compose logs -f redis

# 4. Tenant Web Application (PHP-FPM access & error logs):
docker compose logs -f moodle-app-lms2

# 5. Tenant Background Cron:
docker compose logs -f moodle-cron-lms2
```

---

### C. Interactive Shell Access

#### Standard Shell Access:
```bash
# Using Docker Compose (from project root):
docker compose exec -it moodle-app-lms2 bash

# Using Direct Docker Exec (works anywhere on the system):
docker exec -it moodle-app-lms2 bash

# As www-data user via MoodleKit CLI:
./moodlekit-docker.py site exec lms2 -- bash
```

---

### D. Running Official Moodle Diagnostics
```bash
# Run official Moodle status & router checks:
docker exec moodle-app-lms2 php /var/www/html/admin/cli/checks.php

# Test PHP-FPM syntax and pool parameters:
docker exec moodle-app-lms2 php-fpm -tt

# Purge all Moodle caches:
docker exec moodle-app-lms2 php /var/www/html/admin/cli/purge_caches.php

# Check database schema integrity:
docker exec moodle-app-lms2 php /var/www/html/admin/cli/check_database_schema.php
```

---

### E. Common Issues & Instant Fixes

#### Issue 1: "502 Bad Gateway" or "503 Service Unavailable"
- **Cause**: PHP-FPM container is starting up, restarting, or overloaded.
- **Fix**: Check `docker compose logs -f moodle-app-<slug>`. If overloaded, scale the plan:
  ```bash
  ./moodlekit-docker.py site resize <slug> --plan big
  ```

#### Issue 2: "Exception - Failed to connect to Redis"
- **Cause**: Redis password mismatch or Redis container restarting.
- **Fix**: Re-sync password from `.env`:
  ```bash
  docker compose -f docker/compose.core.yml --env-file .env up -d --force-recreate redis
  ```

#### Issue 3: "Reverse proxy enabled so the server cannot be accessed directly"
- **Cause**: `$CFG->reverseproxy` was set to `true` instead of `false`.
- **Fix**: Ensure `$CFG->reverseproxy = false;` in `sites/<slug>/code/config.php`.

#### Issue 4: "Folder or file permission denied during plugin install"
- **Fix**: Run the permission fixer:
  ```bash
  ./moodlekit-docker.py site fix-perms <slug> --mode standard
  ```

---

## 10. CLI Command Reference Cheat Sheet

```bash
# ── Core Operations ────────────────────────────────────────────────────────
./moodlekit-docker.py init                      # Bootstrap shared core infrastructure
./moodlekit-docker.py build                     # Build optimized PHP 8.3 FPM image
./moodlekit-docker.py tune                      # Hardware RAM auto-tuning
./moodlekit-docker.py status                    # Cluster health & tenant table

# ── Tenant Operations ──────────────────────────────────────────────────────
./moodlekit-docker.py site plans                # List sizing profiles (small, medium, big, enterprise)
./moodlekit-docker.py site create <slug>        # Create a new tenant site
./moodlekit-docker.py site resize <slug> --plan # Hot-scale tenant capacity with 0 downtime
./moodlekit-docker.py site list                 # List all tenants
./moodlekit-docker.py site fix-perms <slug>     # Enforce strict Moodle security permissions
./moodlekit-docker.py site cron <slug>          # Run immediate background cron
./moodlekit-docker.py site exec <slug> -- <cmd> # Execute command as www-data
./moodlekit-docker.py site backup <slug>        # Backup tenant (SQL + Code + Data)
./moodlekit-docker.py site restore <slug> <tar> # Restore tenant archive
./moodlekit-docker.py site remove <slug>        # Teardown tenant & drop database
```
