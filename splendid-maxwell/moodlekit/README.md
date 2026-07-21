# MoodleKit

A comprehensive, modular CLI tool for provisioning and managing Moodle servers and tenants on Ubuntu (22.04 / 24.04).

## Features
- **Server Bootstrap**: Installs PHP (8.1/8.3/8.4), Nginx, PostgreSQL/MariaDB/MySQL, Redis, Memcached, Certbot, UFW, and fail2ban.
- **Tenant Provisioning**: 12-step automated creation of Moodle 4.x or 5.x tenants with automatic database creation, code cloning, Nginx vhost setup, Let's Encrypt TLS, and cron configuration.
- **Auto-Tuning**: RAM-aware calculation of PHP-FPM workers, database buffers, and Redis maxmemory based on available hardware and number of active sites.
- **Cloud Backups**: Integrated Python-based backup script wrapping `rclone` for automated Google Drive syncing with live Telegram progress updates.
- **Two-Method Restore**: Restore backups in-place to an existing tenant, or provision a fresh instance directly from a backup manifest.
- **Rollback System**: Atomic operations during provisioning — if a step fails, the LIFO rollback stack unwinds the changes cleanly.

## Installation

```bash
sudo ./install.sh
```

## Usage

### 1. Server Bootstrap
Run this once on a fresh Ubuntu server:
```bash
sudo moodlekit bootstrap
```
Follow the interactive prompts to select your stack (PHP version, Database type, Caching, etc.).

### 2. Create a Site
```bash
sudo moodlekit site create mysite
```
Follow the prompts to select Moodle version (e.g. 5.2 or 4.5). The script handles cloning, installation, Nginx configuration, TLS, and cron setup.

### 3. List Sites
```bash
sudo moodlekit site list
```

### 4. Backups
Deploy the cloud backup system (runs daily via systemd):
```bash
sudo moodlekit backup deploy
```
*Note: Edit `/opt/moodlekit-data/backup/config.json` and `secrets.json` to configure rclone and Telegram.*

Run a manual local backup:
```bash
sudo moodlekit backup mysite
```

### 5. Server Tuning
Recalculate and apply memory limits (e.g. after adding more RAM):
```bash
sudo moodlekit tune balanced
```

### 6. Status
View server health, hardware, and service status:
```bash
sudo moodlekit status
```
