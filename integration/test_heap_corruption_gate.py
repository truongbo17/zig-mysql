import importlib.util
from pathlib import Path
import unittest


def load_profiler():
    path = Path(__file__).resolve().parents[1] / "bench" / "profile_runner.py"
    spec = importlib.util.spec_from_file_location("profile_runner", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HeapCorruptionGateTest(unittest.TestCase):
    def test_glibc_fasttop_is_fatal(self):
        self.assertTrue(load_profiler().has_fatal_output(
            "double free or corruption (fasttop)"))

    def test_sigsegv_is_fatal(self):
        self.assertTrue(load_profiler().has_fatal_output(
            "error: process terminated with signal SEGV"))

    def test_normal_benchmark_is_not_fatal(self):
        self.assertFalse(load_profiler().has_fatal_output(
            "D4_CCU tls=1 workers=128 req_s=1400"))


if __name__ == "__main__":
    unittest.main()
