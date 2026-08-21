# MoodleKit

A comprehensive, modular CLI toolkit for diagnosing, repairing, managing, provisioning, and backing up Moodle LMS installations and servers on Ubuntu (22.04 / 24.04).

Supports both **Standalone Moodle sites** (located anywhere on disk) and **Multi-Tenant clusters**, backed by an **AES-256 Encrypted Binary Vault** for secure credential management.

---

## Key Features

- **Moodle Doctor & Fixer (`moodlekit fix`)**: Automated diagnostics and 1-click repair for file permissions, dataroot corruption, database connectivity, table repair, PHP configuration limits, missing PHP-FPM pools, Nginx vhost routing, cron execution, task queue locks, and cache purging.
- **Standalone Site Adoption (`moodlekit adopt`)**: Discover existing unmanaged Moodle installations across your server and seamlessly register them into MoodleKit management.
- **AES-256 Encrypted Binary Vault**: Replaces plaintext `.conf` and `secrets.json` files with authenticated AES-256-CBC + HMAC-SHA256 (PBKDF2 100,000 iterations) storage (`/etc/moodlekit/vault.bin`), protected by a strict `0600` master key.
- **Server Bootstrap & Auto-Tuning**: Non-destructive server provisioning for PHP (8.1/8.3/8.4), Nginx, PostgreSQL 17/MariaDB/MySQL, Redis, Memcached, Certbot, UFW, and fail2ban, with RAM-aware dynamic auto-tuning.
- **Automated Cloud Backups & Cloud Sync**: Local backup generation (database dump, config, dataroot, and manifest) + automated Google Drive sync via `rclone` with live Telegram progress notifications.
- **Flexible 3-Method Restore**: Restore in-place into existing sites, provision fresh instances from backup manifests, or perform legacy recovery from raw `.sql` and data archives.

---

## Installation

```bash
sudo ./install.sh
```

---

## Usage

### 1. Moodle Doctor & Repair (Fix Common Issues)
Diagnose and repair permissions, dataroot, database, PHP-FPM pools, Nginx, and caches:
```bash
sudo moodlekit fix
# Or target a specific site or path:
sudo moodlekit fix mysite
sudo moodlekit fix /var/www/html
```

### 2. Adopt an Existing Standalone Moodle Site
Discover and register existing Moodle installations on your server into the encrypted vault:
```bash
sudo moodlekit adopt
# Or specify path:
sudo moodlekit adopt /var/www/html mysite
```

### 3. Server Status & Diagnostics
Check server health, running services, encrypted vault state, and detected Moodle instances:
```bash
sudo moodlekit status
```

### 4. Create a New Moodle Site / Tenant
```bash
sudo moodlekit site create mysite
```
Follow interactive prompts to select Moodle version (5.2 or 4.5 LTS), domain, database, and caching.

### 5. List Managed & Unmanaged Sites
```bash
sudo moodlekit site list
```

### 6. Upgrade a Moodle Site
```bash
sudo moodlekit site upgrade mysite
```

### 7. Backups & Cloud Sync
Deploy automated daily cloud backups with live Telegram progress:
```bash
sudo moodlekit backup deploy
```

Run a manual backup of a site:
```bash
sudo moodlekit backup mysite
# Or backup all sites:
sudo moodlekit backup all
```

### 8. Restore a Site
```bash
sudo moodlekit restore mysite /var/backups/moodlekit/mysite/20260821_120000
# Or manual recovery from raw SQL:
sudo moodlekit restore manual
```

### 9. Encrypted Vault Management
```bash
sudo moodlekit vault status
sudo moodlekit vault dump
```

### 10. Server Performance Tuning
```bash
sudo moodlekit tune balanced
```
Modes: `balanced`, `conservative`, `aggressive`.
