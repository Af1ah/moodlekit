#!/usr/bin/env python3
"""
Unit and integration test suite for MoodleKit Docker Orchestrator
"""

import importlib.util
import os
import shutil
import tempfile
import unittest
from pathlib import Path

# Dynamically import moodlekit-docker
BASE_DIR = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("moodlekit_docker", str(BASE_DIR / "moodlekit-docker.py"))
moodlekit_docker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(moodlekit_docker)


class TestMoodleKitDocker(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_gen_password(self):
        pw1 = moodlekit_docker.gen_password(16)
        pw2 = moodlekit_docker.gen_password(24)
        self.assertEqual(len(pw1), 16)
        self.assertEqual(len(pw2), 24)
        self.assertNotEqual(pw1, pw2)

    def test_sizing_profiles(self):
        self.assertIn("small", moodlekit_docker.SIZING_PROFILES)
        self.assertIn("medium", moodlekit_docker.SIZING_PROFILES)
        self.assertIn("big", moodlekit_docker.SIZING_PROFILES)
        self.assertIn("enterprise", moodlekit_docker.SIZING_PROFILES)

        self.assertEqual(moodlekit_docker.SIZING_PROFILES["small"]["fpm_pm"], "ondemand")
        self.assertEqual(moodlekit_docker.SIZING_PROFILES["big"]["fpm_max_children"], "60")
        self.assertEqual(moodlekit_docker.SIZING_PROFILES["enterprise"]["fpm_max_children"], "120")

    def test_render_config_php_moodle5_mariadb(self):
        tpl_path = BASE_DIR / "docker" / "templates" / "config.php.tpl"
        context = {
            "SLUG": "tenant1",
            "DOMAIN": "tenant1.example.com",
            "WWWROOT": "https://tenant1.example.com",
            "DB_TYPE": "mariadb",
            "IS_POSTGRES": False,
            "DB_HOST": "db",
            "DB_PORT": "3306",
            "DB_NAME": "moodle_tenant1",
            "DB_USER": "moodle_tenant1",
            "DB_PASS": "secretpass123",
            "DB_PREFIX": "mdl_",
            "SSLPROXY": "true",
            "IS_MOODLE5": True,
            "USE_REDIS_SESSIONS": True,
            "REDIS_HOST": "redis",
            "REDIS_PORT": 6379,
            "REDIS_AUTH": "redispassword",
        }
        rendered = moodlekit_docker.render_template(tpl_path, context)
        self.assertIn("$CFG->wwwroot   = 'https://tenant1.example.com';", rendered)
        self.assertIn("$CFG->dbtype    = 'mariadb';", rendered)
        self.assertIn("$CFG->dbname    = 'moodle_tenant1';", rendered)
        self.assertIn("$CFG->routerconfigured = true;", rendered)
        self.assertIn("$CFG->session_handler_class = '\\core\\session\\redis';", rendered)
        self.assertIn("$CFG->session_redis_prefix  = 'tenant1_sess_';", rendered)
        self.assertIn("$CFG->xsendfile        = 'X-Accel-Redirect';", rendered)
        self.assertIn("$CFG->directorypermissions = 02775;", rendered)
        self.assertIn("$CFG->filepermissions      = 0664;", rendered)
        self.assertIn("'dbcollation'   => 'utf8mb4_unicode_ci'", rendered)

    def test_render_config_php_pgsql(self):
        tpl_path = BASE_DIR / "docker" / "templates" / "config.php.tpl"
        context = {
            "SLUG": "tenant_pg",
            "DOMAIN": "pg.example.com",
            "WWWROOT": "https://pg.example.com",
            "DB_TYPE": "pgsql",
            "IS_POSTGRES": True,
            "DB_HOST": "postgres",
            "DB_PORT": "5432",
            "DB_NAME": "moodle_tenant_pg",
            "DB_USER": "moodle_tenant_pg",
            "DB_PASS": "pgsecret123",
            "DB_PREFIX": "mdl_",
            "SSLPROXY": "true",
            "IS_MOODLE5": False,
            "USE_REDIS_SESSIONS": True,
            "REDIS_HOST": "redis",
            "REDIS_PORT": 6379,
            "REDIS_AUTH": "",
        }
        rendered = moodlekit_docker.render_template(tpl_path, context)
        self.assertIn("$CFG->dbtype    = 'pgsql';", rendered)
        self.assertIn("$CFG->dbhost    = 'postgres';", rendered)
        self.assertIn("'dbport'        => '5432'", rendered)
        self.assertIn("'dbcollation'   => 'utf8'", rendered)

    def test_render_caddy_route(self):
        tpl_path = BASE_DIR / "docker" / "templates" / "site.caddy.tpl"
        context = {
            "SLUG": "tenant1",
            "DOMAIN": "academy.example.com",
            "UPSTREAM": "moodle-app-tenant1:9000",
            "WEB_ROOT": "/var/www/html/tenant1/code/public",
            "CONTAINER_ROOT": "/var/www/html/public",
        }
        rendered = moodlekit_docker.render_template(tpl_path, context)
        self.assertIn("academy.example.com {", rendered)
        self.assertIn("import moodle_site moodle-app-tenant1:9000 /var/www/html/tenant1/code/public /var/www/html/public", rendered)

    def test_render_tenant_compose_with_sizing_limits(self):
        tpl_path = BASE_DIR / "docker" / "templates" / "tenant-compose.yml.tpl"
        context = {
            "SLUG": "tenant1",
            "DOMAIN": "tenant1.local",
            "BASE_DIR": "/home/moodle",
            "IMAGE_NAME": "moodlekit/moodle-app:8.3",
            "DB_TYPE": "mariadb",
            "DB_HOST": "db",
            "DB_PORT": "3306",
            "DB_NAME": "moodle_tenant1",
            "DB_USER": "moodle_tenant1",
            "DB_PASS": "pass123",
            "REDIS_AUTH": "redispass",
            "MOODLEDATA_PATH": "/home/moodle/sites/tenant1/moodledata",
            "PLAN_NAME": "big",
            "PLAN_DESC": "Big Plan",
            "FPM_PM": "dynamic",
            "FPM_MAX_CHILDREN": "60",
            "FPM_START_SERVERS": "8",
            "FPM_MIN_SPARE": "4",
            "FPM_MAX_SPARE": "15",
            "FPM_IDLE_TIMEOUT": "10s",
            "FPM_MAX_REQUESTS": "1000",
            "PHP_MEM_LIMIT": "512M",
            "CPU_LIMIT": "3.5",
            "MEM_LIMIT": "5.0g",
        }
        rendered = moodlekit_docker.render_template(tpl_path, context)
        self.assertIn("container_name: moodle-app-tenant1", rendered)
        self.assertIn("container_name: moodle-cron-tenant1", rendered)
        self.assertIn("FPM_MAX_CHILDREN: \"60\"", rendered)
        self.assertIn("memory: \"5.0g\"", rendered)
        self.assertIn("cpus: \"3.5\"", rendered)
        self.assertIn("docker-cron-entrypoint.sh", rendered)

    def test_parse_moodle_config_php_mariadb(self):
        cfg_file = self.test_dir / "config_mariadb.php"
        cfg_file.write_text("""<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype    = 'mysqli';
$CFG->dblibrary = 'native';
$CFG->dbhost    = '127.0.0.1';
$CFG->dbname    = 'moodle_legacy';
$CFG->dbuser    = 'moodleuser';
$CFG->dbpass    = 'legacy_pass_123';
$CFG->prefix    = 'mdl_';
$CFG->wwwroot   = 'https://legacy-school.org';
$CFG->dataroot  = '/var/moodledata_legacy';
""")
        parsed = moodlekit_docker.parse_moodle_config_php(cfg_file)
        self.assertEqual(parsed["dbtype"], "mariadb")
        self.assertEqual(parsed["dbhost"], "127.0.0.1")
        self.assertEqual(parsed["dbname"], "moodle_legacy")
        self.assertEqual(parsed["dbuser"], "moodleuser")
        self.assertEqual(parsed["dbpass"], "legacy_pass_123")
        self.assertEqual(parsed["prefix"], "mdl_")
        self.assertEqual(parsed["wwwroot"], "https://legacy-school.org")
        self.assertEqual(parsed["dataroot"], "/var/moodledata_legacy")

    def test_parse_moodle_config_php_pgsql(self):
        cfg_file = self.test_dir / "config_pgsql.php"
        cfg_file.write_text("""<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'localhost';
$CFG->dbname    = 'moodle_pg_legacy';
$CFG->dbuser    = 'pg_moodle_user';
$CFG->dbpass    = 'pg_password_999';
$CFG->prefix    = 'mdl2_';
$CFG->dboptions = array('dbport' => 5432);
$CFG->wwwroot   = 'http://moodle-pg.internal';
$CFG->dataroot  = '/opt/data/moodledata';
""")
        parsed = moodlekit_docker.parse_moodle_config_php(cfg_file)
        self.assertEqual(parsed["dbtype"], "pgsql")
        self.assertEqual(parsed["dbport"], "5432")
        self.assertEqual(parsed["dbname"], "moodle_pg_legacy")
        self.assertEqual(parsed["dbuser"], "pg_moodle_user")
        self.assertEqual(parsed["prefix"], "mdl2_")
        self.assertEqual(parsed["wwwroot"], "http://moodle-pg.internal")
        self.assertEqual(parsed["dataroot"], "/opt/data/moodledata")

    def test_get_db_driver(self):
        env = {"DB_ROOT_PASSWORD": "secret_mariadb", "POSTGRES_PASSWORD": "secret_pg"}
        driver_mysql = moodlekit_docker.get_db_driver("mariadb", env)
        driver_pg = moodlekit_docker.get_db_driver("pgsql", env)

        self.assertIsInstance(driver_mysql, moodlekit_docker.MariaDBDriver)
        self.assertEqual(driver_mysql.port, 3306)
        self.assertIsInstance(driver_pg, moodlekit_docker.PostgresDriver)
        self.assertEqual(driver_pg.port, 5432)

    def test_cli_parser(self):
        parser = moodlekit_docker.build_parser()
        
        args = parser.parse_args(["site", "create", "testsite", "-d", "testsite.org", "--plan", "big", "--db-type", "pgsql", "-m", "5.2"])
        self.assertEqual(args.command, "site")
        self.assertEqual(args.subcommand, "create")
        self.assertEqual(args.slug, "testsite")
        self.assertEqual(args.domain, "testsite.org")
        self.assertEqual(args.db_type, "pgsql")
        self.assertEqual(args.plan, "big")
        self.assertEqual(args.moodle_version, "5.2")

        args_adopt = parser.parse_args(["site", "adopt", "adopted_site", "--source-code", "/var/www/moodle", "--plan", "big", "--link-data"])
        self.assertEqual(args_adopt.command, "site")
        self.assertEqual(args_adopt.subcommand, "adopt")
        self.assertEqual(args_adopt.slug, "adopted_site")
        self.assertEqual(args_adopt.source_code, "/var/www/moodle")
        self.assertEqual(args_adopt.plan, "big")
        self.assertTrue(args_adopt.link_data)

        args_resize = parser.parse_args(["site", "resize", "testsite", "--plan", "enterprise"])
        self.assertEqual(args_resize.command, "site")
        self.assertEqual(args_resize.subcommand, "resize")
        self.assertEqual(args_resize.slug, "testsite")
        self.assertEqual(args_resize.plan, "enterprise")

        args_plans = parser.parse_args(["site", "plans"])
        self.assertEqual(args_plans.command, "site")
        self.assertEqual(args_plans.subcommand, "plans")

    def test_tar_filter_excludes_ephemeral_caches(self):
        import tarfile
        tar_path = self.test_dir / "test.tar.gz"
        source_dir = self.test_dir / "moodledata"
        source_dir.mkdir()
        (source_dir / "filedir").mkdir()
        (source_dir / "filedir" / "important_file.pdf").write_text("course file")
        (source_dir / "cache").mkdir()
        (source_dir / "cache" / "trash.tmp").write_text("cache file")
        (source_dir / "localcache").mkdir()
        (source_dir / "localcache" / "temp.tmp").write_text("localcache file")
        (source_dir / "sessions").mkdir()
        (source_dir / "sessions" / "sess_123").write_text("session file")

        def exclude_ephemeral(tarinfo):
            norm = "/" + tarinfo.name.strip("/") + "/"
            for ex in ["cache", "localcache", "temp", "trashdir", "sessions", "muc"]:
                if f"/moodledata/{ex}/" in norm or f"/{ex}/" in norm:
                    return None
            return tarinfo

        with tarfile.open(tar_path, "w:gz") as tar:
            tar.add(source_dir, arcname="moodledata", filter=exclude_ephemeral)

        with tarfile.open(tar_path, "r:gz") as tar:
            names = tar.getnames()
            self.assertIn("moodledata/filedir/important_file.pdf", names)
            self.assertNotIn("moodledata/cache/trash.tmp", names)
            self.assertNotIn("moodledata/localcache/temp.tmp", names)
            self.assertNotIn("moodledata/sessions/sess_123", names)


if __name__ == "__main__":
    unittest.main()
