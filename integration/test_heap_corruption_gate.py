import unittest

FATAL = ("double free or corruption", "malloc():", "corrupted size vs.",
         "free(): invalid pointer", "signal SEGV", "Segmentation fault")


class HeapCorruptionGateTest(unittest.TestCase):
    def test_glibc_fasttop_is_fatal(self):
        self.assertTrue(any(x in "double free or corruption (fasttop)" for x in FATAL))

    def test_normal_benchmark_is_not_fatal(self):
        self.assertFalse(any(x in "D4_CCU tls=1 workers=128 req_s=1400" for x in FATAL))


if __name__ == "__main__":
    unittest.main()
