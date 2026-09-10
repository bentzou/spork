import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "tunnels", Path(__file__).resolve().parents[1] / "close-tunnels.py"
)
tunnels = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tunnels)
COMMAND = ("bash -c gcloud compute ssh sql-bastion --project=ploy-production "
           "--zone=us-central1-a --tunnel-through-iap -- -N -L 25432:10.176.0.4:5432; "
           "read -p 'Tunnel exited. Press Enter to close.'")


class TunnelTests(unittest.TestCase):
    def test_background_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / ".spork").symlink_to(Path(__file__).resolve().parents[2])
            local = workspace / ".spork.local"
            local.mkdir()
            (local / "config").write_text("ORIGIN_URL=test:tunnel.git\nTRUNK_BRANCH=main\n")
            clone = workspace / "p1"
            subprocess.run(["git", "init", "-q", str(clone)], check=True)
            subprocess.run(["git", "-C", str(clone), "remote", "add", "origin",
                            "test:tunnel.git"], check=True)
            (clone / "keep.txt").write_text("unfinished work")
            executable = workspace / "gcloud"
            executable.write_text("#!/bin/sh\nexec sleep 60\n")
            executable.chmod(0o755)
            children = []
            def launch(command):
                child = subprocess.Popen(
                    ["bash", "-c", command], cwd=clone,
                    env={**os.environ, "PATH": directory + ":" + os.environ["PATH"]},
                    start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                children.append(child)
                time.sleep(0.05)
                return child
            def recover():
                # Exercise the actual sync entrypoint, including the no-mirror path.
                result = subprocess.run(["bash", str(workspace / ".spork/tools/sync-bg.sh")],
                                        cwd=workspace, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            try:
                tunnel = launch(COMMAND.removeprefix("bash -c "))
                claim = local / "runtime/claims/p1"
                claim.mkdir(parents=True)
                (claim / "pid").write_text(str(os.getpid()))
                recover()
                self.assertIsNone(tunnel.poll(), "live claim protects tunnel")
                (claim / "pid").unlink()
                claim.rmdir()
                shell = launch("sleep 60; echo done")
                recover()
                self.assertIsNone(tunnel.poll(), "ordinary shell protects tunnel")
                os.killpg(shell.pid, 15)
                shell.wait(timeout=5)
                recover()
                self.assertEqual(tunnel.wait(timeout=5), -15)
                self.assertEqual((clone / "keep.txt").read_text(), "unfinished work")
                log = (local / "runtime/sync.log").read_text()
                self.assertIn("p1: Closing tunnel terminal", log)
            finally:
                for child in children:
                    if child.poll() is None:
                        os.killpg(child.pid, 15)
                        child.wait(timeout=5)

    def test_agent_blocks_automatic_recovery(self):
        rows = {100: (1, 100, os.getuid(), COMMAND),
                101: (1, 101, os.getuid(), "claude")}
        def run(args, **kwargs):
            if args[0] == "pgrep":
                return subprocess.CompletedProcess(args, 0, "101\n")
            return subprocess.CompletedProcess(args, 0, "n/private/tmp/p1\n")
        with patch.object(tunnels.subprocess, "run", side_effect=run):
            self.assertTrue(tunnels.other_occupants("/private/tmp/p1", rows))

    def test_narrow_wrapper(self):
        self.assertIsNotNone(tunnels.WRAPPER.fullmatch(COMMAND))
        for command in ["bash", "bash -l", COMMAND + "; echo other-work",
                        COMMAND.replace("-N -L", "-L"),
                        COMMAND.replace("sql-bastion", "$(something)")]:
            self.assertIsNone(tunnels.WRAPPER.fullmatch(command))

    def test_dedicated_group(self):
        rows = {100: (1, 100, os.getuid(), COMMAND),
                101: (100, 100, os.getuid(), "gcloud"),
                102: (101, 100, os.getuid(), "ssh")}
        self.assertTrue(tunnels.dedicated(100, rows))
        rows[103] = (1, 100, os.getuid(), "unrelated")
        self.assertFalse(tunnels.dedicated(100, rows))
        rows[100] = (1, 99, os.getuid(), COMMAND)
        self.assertFalse(tunnels.dedicated(100, rows))

    def test_cwd_boundary(self):
        for cwd, expected in [("/tmp/p2/subdir", True), ("/tmp/p2", True),
                              ("/tmp/p20", False), ("/tmp/p3", False)]:
            result = subprocess.CompletedProcess([], 0, "n" + cwd + "\n")
            with patch.object(tunnels.subprocess, "run", return_value=result):
                self.assertEqual(tunnels.inside(100, os.path.realpath("/tmp/p2")), expected)

    def test_real_group_shutdown(self):
        # A fake gcloud sleeps locally; the wrapper and process group are real.
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "gcloud"
            executable.write_text("#!/bin/sh\nexec sleep 60\n")
            executable.chmod(0o755)
            process = subprocess.Popen(
                ["bash", "-c", COMMAND.removeprefix("bash -c ")],
                cwd=directory, env={**os.environ, "PATH": directory + ":" + os.environ["PATH"]},
                start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                tunnels.close(directory + "/different-clone")
                self.assertIsNone(process.poll())
                tunnels.close(directory)
                self.assertEqual(process.wait(timeout=5), -15)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 15)
                    process.wait(timeout=5)

    def test_clean_closes_tunnel_after_loss_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / ".spork").symlink_to(Path(__file__).resolve().parents[2])
            (workspace / ".spork.local").mkdir()
            (workspace / ".spork.local/config").write_text(
                "ORIGIN_URL=test:tunnel.git\nTRUNK_BRANCH=main\n"
            )
            clone = workspace / "p1"
            subprocess.run(["git", "init", "-q", str(clone)], check=True)
            def git(*args):
                return subprocess.run(["git", "-C", str(clone), *args], check=True)
            git("symbolic-ref", "HEAD", "refs/heads/main")
            git("-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "-q", "--allow-empty", "-m", "init")
            git("remote", "add", "origin", "test:tunnel.git")
            executable = workspace / "gcloud"
            executable.write_text("#!/bin/sh\nexec sleep 60\n")
            executable.chmod(0o755)
            process = subprocess.Popen(
                ["bash", "-c", COMMAND.removeprefix("bash -c ")], cwd=clone,
                env={**os.environ, "PATH": directory + ":" + os.environ["PATH"]},
                start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            env = {k: v for k, v in os.environ.items() if not k.startswith("SPORK_PROC_SWEEP")}
            def clean():
                return subprocess.run([str(workspace / ".spork/tools/clean.sh"), "p1"],
                                      cwd=workspace, env=env, capture_output=True, text=True)
            try:
                (clone / "work.txt").touch()
                self.assertEqual(clean().returncode, 1)
                self.assertIsNone(process.poll())
                (clone / "work.txt").unlink()
                result = clean()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Closing tunnel terminal", result.stdout)
                self.assertEqual(process.wait(timeout=5), -15)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 15)
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
