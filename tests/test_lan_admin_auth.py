import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class LanAdminAuthStaticTests(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_privileged_apis_use_shared_gate(self):
        for name in (
            "archive.php",
            "birdnet-status.php",
            "config.php",
            "export.php",
            "generate.php",
            "maintenance.php",
            "menu.php",
        ):
            source = self.read(f"avian/api/{name}")
            self.assertIn("admin-auth.php", source, name)
            self.assertIn("avian_require_admin();", source, name)

    def test_public_data_apis_are_not_blanket_locked(self):
        for name in ("birdnet-api.php", "recording.php", "spectrogram.php", "wiki.php"):
            self.assertNotIn("avian_require_admin();", self.read(f"avian/api/{name}"), name)

    def test_root_owned_state_is_the_only_runtime_authority(self):
        state = self.read("avian/api/admin-state.php")
        auth = self.read("avian/api/admin-auth.php")
        root = self.read("scripts/admin_control.sh")
        self.assertIn("/var/lib/avian-visitors/admin-auth.state", state)
        self.assertIn("\\$2y\\$14\\$", state)
        self.assertIn("admin-auth.initialized", root)
        self.assertIn("auth-state-init)", root)
        self.assertIn("lan-auth-set-stdin)", root)
        self.assertIn("password-change-stdin)", root)
        self.assertNotIn("CADDY_PWD", auth)

    def test_missing_or_invalid_state_fails_closed(self):
        state = self.read("avian/api/admin-state.php")
        auth = self.read("avian/api/admin-auth.php")
        self.assertIn("'required' => true", state)
        self.assertIn("admin credential state is missing or invalid", auth)
        self.assertIn("AVIAN_FORCE_AUTH", auth)
        force = auth.index("AVIAN_FORCE_AUTH")
        override = auth.index("AV_REQUIRE_AUTH")
        self.assertLess(force, override)

    def test_rate_limiter_uses_one_bounded_root_provisioned_file(self):
        auth = self.read("avian/api/admin-auth.php")
        install = self.read("scripts/install_services.sh")
        security = self.read("scripts/security_refresh.sh")
        self.assertIn("admin-auth.rate", auth)
        self.assertIn("AVIAN_ADMIN_RATE_MAX_ENTRIES", auth)
        self.assertIn("IPv6 /64", auth)
        self.assertNotIn(".avian-login-", auth)
        self.assertIn("auth-state-init", install)
        self.assertIn("auth-state-init", security)

    def test_install_initializes_state_before_first_caddy_render(self):
        install = self.read("scripts/install_services.sh")
        init = install.index("auth-state-init")
        caddy = install.index("install_Caddyfile")
        self.assertLess(init, caddy)
        self.assertIn("auth-state-init", self.read("scripts/security_refresh.sh"))

    def test_caddy_uses_state_and_closes_required_surfaces(self):
        source = self.read("scripts/update_caddyfile.sh")
        self.assertIn("admin-auth.state", source)
        self.assertIn("AVIAN_FORCE_AUTH", source)
        self.assertIn("AVIAN_CLOSE_STREAMS", source)
        self.assertIn("@legacySurface", source)
        self.assertIn("respond @executableSource 404", source)

    def test_caddy_barrier_is_atomic_and_durable_before_reload(self):
        source = self.read("scripts/update_caddyfile.sh")
        candidate = source.index('sync -f "$temp"')
        rename = source.index('mv -fT "$temp" /etc/caddy/Caddyfile', candidate)
        active_sync = source.index('sync -f /etc/caddy/Caddyfile', rename)
        directory_sync = source.index(
            'sync -f /etc/caddy', active_sync + len('sync -f /etc/caddy/Caddyfile')
        )
        reload = source.index('systemctl "$caddy_action" caddy', directory_sync)
        self.assertLess(candidate, rename)
        self.assertLess(rename, active_sync)
        self.assertLess(active_sync, directory_sync)
        self.assertLess(directory_sync, reload)

        rollback = source.index('sync -f "$rollback"', reload)
        rollback_rename = source.index(
            'mv -fT "$rollback" /etc/caddy/Caddyfile', rollback
        )
        rollback_file_sync = source.index(
            'sync -f /etc/caddy/Caddyfile', rollback_rename
        )
        rollback_dir_sync = source.index(
            'sync -f /etc/caddy',
            rollback_file_sync + len('sync -f /etc/caddy/Caddyfile'),
        )
        self.assertLess(rollback, rollback_rename)
        self.assertLess(rollback_rename, rollback_file_sync)
        self.assertLess(rollback_file_sync, rollback_dir_sync)

    def test_root_state_sync_failures_are_not_suppressed_by_conditionals(self):
        source = self.read("scripts/admin_control.sh")
        self.assertIn('fail "could not sync admin state"', source)
        self.assertIn('sync -f "$AUTH_DIR" || return 1', source)
        self.assertIn('sync -f "$(dirname "$conf_path")" || return 1', source)

    def test_legacy_password_gate_avoids_repeated_php_bcrypt(self):
        common = self.read("scripts/common.php")
        caddy = self.read("scripts/update_caddyfile.sh")
        self.assertIn("static $cached_proof = null", common)
        self.assertIn("!empty($state['required'])", common)
        self.assertIn("hash_equals($cached_proof, $proof)", common)
        self.assertIn("AVIAN_LEGACY_AUTH", common)
        self.assertEqual(caddy.count("env AVIAN_LEGACY_AUTH 1"), 2)
        self.assertEqual(caddy.count("env AVIAN_LEGACY_AUTH_EPOCH $AVIAN_AUTH_EPOCH"), 2)
        password_branch = caddy.index('elif [ -n "$hashword" ]')
        direct_branch = caddy.index("else\n  legacy_handles=", password_branch)
        for marker in [
            index for index in range(len(caddy))
            if caddy.startswith("env AVIAN_LEGACY_AUTH 1", index)
        ]:
            self.assertGreater(marker, password_branch)
            self.assertLess(marker, direct_branch)

    def test_cold_cutout_never_starts_generation_get_when_required(self):
        source = self.read("avian/api/cutout.php")
        cached = source.index("serve_png($cachePath)")
        policy = source.index("if (avian_lan_admin_auth_required())")
        process = source.index("shell_exec($cmd)")
        self.assertLess(cached, policy)
        self.assertLess(policy, process)

    def test_frontend_security_controls_have_settled_auth_paths(self):
        source = self.read("avian/frontend/apt.js")
        self.assertIn("Require password on local network", source)
        self.assertIn("sudo /usr/local/sbin/avian-admin-control password-reset", source)
        self.assertIn("function AdminAuthCancelled", source)
        self.assertIn("function adminBasicAuthorization", source)
        self.assertIn("new TextEncoder()", source)
        self.assertIn("function sessionReplaced", source)
        self.assertIn("action=idle-lock", source)
        self.assertIn("action=download-grant", source)
        self.assertIn("HTTP_X_AVIAN_CREDENTIAL", self.read("avian/api/admin-auth.php"))
        self.assertNotIn("new Promise(function () {})", source)
        self.assertNotIn("window.AV_AUTH_USER", source)

    def test_frontend_starts_neutral_and_has_current_cache_keys(self):
        source = self.read("avian/frontend/index.html")
        self.assertIn("<body>", source)
        self.assertNotIn("<body class=\"av-local\"", source)
        self.assertRegex(source, r'href="[.]?/styles[.]css[?]v=r[0-9]+"')
        self.assertRegex(source, r'src="[.]?/apt[.]js[?]v=r[0-9]+"')
        self.assertIn('id="lockHint" role="status"', source)
        self.assertIn('aria-live="polite"', source)

    @unittest.skipUnless(shutil.which("php"), "PHP CLI is unavailable")
    def test_php_auth_runtime_suite(self):
        result = subprocess.run(
            ["php", "tests/test_admin_auth.php"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertRegex(result.stdout, r"admin auth tests passed [(][0-9]+ checks[)]")

    @unittest.skipUnless(shutil.which("node"), "Node.js is unavailable")
    def test_frontend_auth_runtime_suite(self):
        result = subprocess.run(
            ["node", "tests/test_admin_frontend_auth.js"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertRegex(result.stdout, r"admin frontend auth tests passed [(][0-9]+ checks[)]")

    @unittest.skipUnless(shutil.which("bash"), "Bash is unavailable")
    def test_auth_shell_files_parse(self):
        paths = [
            "scripts/admin_control.sh",
            "scripts/install_services.sh",
            "scripts/security_refresh.sh",
            "scripts/update_caddyfile.sh",
            "tests/smoke_admin_control.sh",
            "tests/smoke_caddy_generated_routes.sh",
            "tests/smoke_caddy_live_transition.sh",
        ]
        result = subprocess.run(
            ["bash", "-n", *paths],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_stale_passive_session_does_not_expire_fresh_cookie(self):
        source = self.read("avian/api/admin-auth.php")
        self.assertIn("bool $expireInvalidCookie = false", source)
        self.assertIn("avian_destroy_admin_session($server, $expireInvalidCookie)", source)
        self.assertIn("false, true, false, false", source)

    def test_http_restart_excludes_caddy_and_php_fpm(self):
        api = self.read("avian/api/birdnet-status.php")
        frontend = self.read("avian/frontend/apt.js")
        self.assertIn("restartable", api)
        self.assertIn("status only", frontend)
        self.assertIn("caddy", api)
        self.assertIn("php8.4-fpm", api)

    def test_include_only_state_file_is_not_an_endpoint(self):
        caddy = self.read("scripts/update_caddyfile.sh")
        self.assertIn("@unknownAvianApi", caddy)
        self.assertIn("handle @unknownAvianApi", caddy)
        self.assertNotIn("/avian/api/admin-state.php", caddy)


if __name__ == "__main__":
    unittest.main()
