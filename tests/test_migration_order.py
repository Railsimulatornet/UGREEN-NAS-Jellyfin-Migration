"""Migration ordering and failure recovery with shell stubs, never a Docker daemon."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("JELLYFIN_MIGRATION_SOURCE", REPO / "UGREEN-NAS-Jellyfin-Migration-v1.0.0/start.sh"))
SOURCE = SCRIPT.read_text()


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S)
    if not match:
        raise RuntimeError("Function not found: " + name)
    return match.group(0)


HELPERS = """
set -u
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_true() { [ "$1" = true ]; }
tr_text() { printf '%s' "$2"; }
log() { :; }
warn() { printf '%s\\n' "$*" >&2; }
fail() { printf '%s\\n' "$*" >&2; exit 1; }
"""
OTHER_STEPS = [
    "generate_compose", "start_new_container", "register_ugos_project_if_requested",
    "refresh_ugos_app_if_requested", "verify_old_app_stopped", "verify_ugos_project_registration",
    "post_start_checks", "remove_old_app_if_allowed", "copy_reports_to_backup",
]


class MigrationOrderTests(unittest.TestCase):
    def test_snapshots_follow_stop(self):
        code = HELPERS + function("execute_mode") + """
paused=false
stop_old_app_if_needed() { paused=true; printf 'stopped\\n'; }
create_backup() { [ "$paused" = true ] || exit 71; printf 'backup\\n'; }
prepare_project() { [ "$paused" = true ] || exit 72; printf 'copy\\n'; }
""" + "\n".join(name + "() { :; }" for name in OTHER_STEPS) + "\nexecute_mode\n"
        for mode in ("SAFE_MIGRATION", "FULL_MIGRATION"):
            with self.subTest(mode=mode):
                result = subprocess.run(["bash", "-c", code], env=dict(os.environ, MIGRATION_MODE=mode),
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ["stopped", "backup", "copy"])

    def run_failure(self, original_running="true", new_running="false", stop_works="true", inspect_works="true"):
        with tempfile.TemporaryDirectory(prefix="migration recovery test ") as temporary:
            root = Path(temporary)
            state = root / "old-running"
            state.write_text(original_running)
            calls = root / "calls"
            env = dict(os.environ, MIGRATION_MODE="SAFE_MIGRATION", STOP_UGREEN_APP="true",
                       UGREEN_CONTAINER="old-app", JELLYFIN_CONTAINER_NAME="new-app",
                       UGREEN_OLD_RESTART_POLICY="", UGREEN_OLD_WAS_RUNNING="false",
                       OLD_APP_MIGRATION_PAUSED="false", OLD_APP_STATUS="unknown",
                       NEW_CONTAINER_STARTED="false", TEST_STATE=str(state), TEST_CALLS=str(calls),
                       TEST_NEW_RUNNING=new_running, TEST_STOP_WORKS=stop_works, TEST_INSPECT_WORKS=inspect_works,
                       LOG_FILE=str(root / "run.log"), WORK_DIR=str(root / "work"), DEBUG_KEEP_WORKDIR="false")
            code = HELPERS + "\n".join(function(name) for name in [
                "execute_mode", "stop_old_app_if_needed", "verify_old_app_stopped", "cleanup", "restore_old_app_after_failure",
            ]) + """
docker() {
  printf '%s\\n' "$*" >> "$TEST_CALLS"
  case "$1" in
    inspect)
      if [ "$2" = new-app ]; then printf '%s' "$TEST_NEW_RUNNING"; return; fi
      case "$4" in
        *MaximumRetryCount*) printf 3 ;;
        *RestartPolicy.Name*) printf on-failure ;;
        *State.Running*) [ "$TEST_INSPECT_WORKS" = true ] || return 1; cat "$TEST_STATE" ;;
        *) return 2 ;;
      esac ;;
    stop) if [ "$TEST_STOP_WORKS" = true ]; then printf false > "$TEST_STATE"; fi ;;
    start) printf true > "$TEST_STATE" ;;
    update) return 0 ;;
    *) return 2 ;;
  esac
}
create_backup() { printf 'snapshot-attempt\\n' >> "$TEST_CALLS"; exit 7; }
prepare_project() { printf 'UNEXPECTED_COPY\\n' >> "$TEST_CALLS"; }
trap cleanup EXIT
execute_mode
"""
            result = subprocess.run(["bash", "-c", code], env=env, capture_output=True, text=True, timeout=10)
            return result, calls.read_text(), state.read_text()

    def test_failed_snapshot_restarts_original_app(self):
        result, calls, state = self.run_failure()
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("snapshot-attempt", calls)
        self.assertIn("update --restart=on-failure:3 old-app", calls)
        self.assertIn("start old-app", calls)
        self.assertEqual(state, "true")
        self.assertNotIn("UNEXPECTED_COPY", calls)

    def test_previously_stopped_app_remains_stopped(self):
        result, calls, state = self.run_failure(original_running="false")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("update --restart=on-failure:3 old-app", calls)
        self.assertNotIn("start old-app", calls)
        self.assertEqual(state, "false")

    def test_running_replacement_prevents_conflicting_restart(self):
        result, calls, state = self.run_failure(new_running="true")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("start old-app", calls)
        self.assertNotIn("update --restart=on-failure:3 old-app", calls)
        self.assertEqual(state, "false")

    def test_stop_must_be_verified_before_snapshot(self):
        result, calls, _ = self.run_failure(stop_works="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("snapshot-attempt", calls)
        self.assertNotIn("UNEXPECTED_COPY", calls)

    def test_unreadable_initial_state_prevents_snapshot(self):
        result, calls, _ = self.run_failure(inspect_works="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("snapshot-attempt", calls)
        self.assertNotIn("stop old-app", calls)

    def test_refresh_restart_must_be_stopped_before_completion(self):
        for mode in ("SAFE_MIGRATION", "FULL_MIGRATION"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="migration refresh test ") as temporary:
                log_file = Path(temporary) / "run.log"
                env = dict(os.environ, MIGRATION_MODE=mode, UGREEN_CONTAINER="old-app", LOG_FILE=str(log_file))
                code = HELPERS + function("execute_mode") + "\n" + function("verify_old_app_stopped") + """
old_running=true
new_running=false
stop_old_app_if_needed() { old_running=false; }
create_backup() { :; }
prepare_project() { :; }
generate_compose() { :; }
start_new_container() { new_running=true; }
register_ugos_project_if_requested() { :; }
refresh_ugos_app_if_requested() { old_running=true; }
docker() {
  case "$1" in
    inspect) printf '%s' "$old_running" ;;
    stop) printf 'second-stop-failed\\n'; return 1 ;;
    *) return 2 ;;
  esac
}
verify_ugos_project_registration() { printf 'UNEXPECTED_CONTINUE\\n'; }
post_start_checks() { printf 'UNEXPECTED_CONTINUE\\n'; }
remove_old_app_if_allowed() { printf 'UNEXPECTED_CONTINUE\\n'; }
copy_reports_to_backup() { printf 'UNEXPECTED_CONTINUE\\n'; }
trap 'printf "old=%s new=%s\\n" "$old_running" "$new_running"' EXIT
execute_mode
printf 'UNEXPECTED_SUCCESS\\n'
"""
                result = subprocess.run(["bash", "-c", code], env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("second-stop-failed", log_file.read_text())
                self.assertIn("old=true new=true", result.stdout)
                self.assertNotIn("UNEXPECTED_CONTINUE", result.stdout)
                self.assertNotIn("UNEXPECTED_SUCCESS", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
