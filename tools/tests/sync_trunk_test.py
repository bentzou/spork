"""Exercise background sync with a local origin and diverged clones."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SyncTrunkTest(unittest.TestCase):
    def test_remote_wins_only_for_clean_unoccupied_trunk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(
                    ["git", "-c", "user.name=Test", "-c", "user.email=t@example.com", *map(str, args)],
                    stderr=subprocess.DEVNULL, text=True).strip()
            origin = root / "origin.git"
            git("init", "--bare", origin)
            git("--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main")
            seed = root / "seed"
            git("clone", origin, seed)
            git("-C", seed, "commit", "--allow-empty", "-m", "base")
            git("-C", seed, "push", "origin", "main")
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / ".spork").symlink_to(Path(__file__).resolve().parents[2])
            local = workspace / ".spork.local"
            runtime = local / "runtime"
            runtime.mkdir(parents=True)
            (local / "config").write_text(f"ORIGIN_URL={origin}\nTRUNK_BRANCH=main\n")
            mirror = runtime / "mirror.git"
            git("clone", "--mirror", origin, mirror)
            tips = {}
            for name in ("p1", "p2", "p3", "p4", "p5"):
                clone = workspace / name
                git("clone", origin, clone)
                git("-C", clone, "remote", "add", "mirror", mirror)
                git("-C", clone, "config", "remote.mirror.fetch", "+refs/heads/*:refs/remotes/origin/*")
                git("-C", clone, "commit", "--allow-empty", "-m", "local work")
                tips[name] = git("-C", clone, "rev-parse", "HEAD")
            (workspace / "p2/work.txt").write_text("keep")
            git("-C", workspace / "p3", "checkout", "-b", "feature")
            claim = runtime / "claims/p4"
            claim.mkdir(parents=True)
            (claim / "pid").write_text(str(os.getpid()))
            git("-C", seed, "commit", "--allow-empty", "-m", "remote work")
            git("-C", seed, "push", "origin", "main")
            target = git("-C", seed, "rev-parse", "HEAD")
            env = {**os.environ, "SPORK_PROC_SWEEP_LOADED": "1",
                   "SPORK_PROC_SWEEP": f"bash\t{workspace}/p5"}
            subprocess.run(["bash", str(workspace / ".spork/tools/sync-bg.sh")],
                           cwd=workspace, env=env, check=True)
            self.assertEqual(git("-C", workspace / "p1", "rev-parse", "HEAD"), target)
            for name in ("p2", "p3", "p4", "p5"):
                self.assertEqual(git("-C", workspace / name, "rev-parse", "HEAD"), tips[name])
            self.assertEqual((workspace / "p2/work.txt").read_text(), "keep")
            git("-C", workspace / "p1", "commit", "--allow-empty", "-m", "new local work")
            local_tip = git("-C", workspace / "p1", "rev-parse", "HEAD")
            origin.rename(root / "unavailable.git")
            subprocess.run(["bash", str(workspace / ".spork/tools/sync-bg.sh")],
                           cwd=workspace, env=env, check=True)
            self.assertEqual(git("-C", workspace / "p1", "rev-parse", "HEAD"), local_tip)


if __name__ == "__main__":
    unittest.main()
