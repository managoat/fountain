import unittest
import urllib.error
from availability import sample, summarize


class AvailabilityTest(unittest.TestCase):
    def test_success_between_failures_splits_rollouts(self):
        rows = [{"at": str(i), "available": ok} for i, ok in enumerate([True, False, True, False, False, True])]
        report = summarize(rows)
        self.assertEqual(report["failed_samples"], 3)
        self.assertEqual(len(report["outages"]), 2)
        self.assertEqual(report["outages"][1], {"last_success": "2", "first_failure": "3", "last_failure": "4", "first_success": "5", "failed_samples": 2})

    def test_outage_at_recording_boundaries_is_censored(self):
        outage = summarize([{"at": "now", "available": False}])["outages"][0]
        self.assertIsNone(outage["last_success"])
        self.assertIsNone(outage["first_success"])

    def test_proxy_generated_503_is_a_failed_sample(self):
        class Proxy:
            def open(self, url, timeout):
                raise urllib.error.HTTPError(url, 503, "no available server", {}, None)
        row = sample("https://example.invalid/health", 1, Proxy())
        self.assertEqual(row["status"], 503)
        self.assertFalse(row["available"])


if __name__ == "__main__":
    unittest.main()
