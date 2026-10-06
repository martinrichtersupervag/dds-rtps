import io
import unittest
from contextlib import redirect_stdout

import compare_junit_reports as mod


class PrintDifferencesTest(unittest.TestCase):
    def test_print_differences_uses_report_timestamps(self):
        report = {
            "first": {"file": "D:/tmp/junit_interoperability_report_2026-08-30-06_18_47.xml"},
            "second": {"file": "D:/tmp/junit_interoperability_report_2026-08-30-16_15_12.xml"},
            "added": [],
            "removed": [],
            "changed": [
                {
                    "test": "suite / case",
                    "differences": {"status": {"first": "failure", "second": "passed"}},
                }
            ],
        }

        output = io.StringIO()
        with redirect_stdout(output):
            mod.print_differences(report)

        text = output.getvalue()
        self.assertIn("##Result for: Differences: 2026-08-30-06_18_47 -> 2026-08-30-16_15_12", text)
        self.assertIn("- 2026-08-30-06_18_47: failure", text)
        self.assertIn("+ 2026-08-30-16_15_12: passed", text)

    def test_print_failure_frequency_summary_marker(self):
        output = io.StringIO()
        with redirect_stdout(output):
            mod.print_failure_frequency_summary([])

        text = output.getvalue()
        self.assertIn("##Result for: Failure frequency across all XML reports", text)


class ChooseFilesTest(unittest.TestCase):
    def test_choose_all_files_sorts_by_date_in_filename_ignoring_mtime(self):
        from pathlib import Path
        import tempfile
        import time

        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)
            # Create older-dated file later in time so its mtime is newer
            file1 = tmppath / "junit_report_2026-08-30-10_00_00.xml"
            file2 = tmppath / "junit_report_2026-09-01-10_00_00.xml"

            file2.write_text("<testsuite/>", encoding="utf-8")
            time.sleep(0.05)
            file1.write_text("<testsuite/>", encoding="utf-8")

            # file1 has newer mtime, but older date in name
            self.assertGreater(file1.stat().st_mtime, file2.stat().st_mtime)

            sorted_files = mod.choose_all_files(tmppath)
            self.assertEqual(sorted_files, [file1, file2])


class GenerateExplanationTest(unittest.TestCase):
    def test_generate_explanation_creates_file_with_required_format(self):
        from pathlib import Path
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)
            first = tmppath / "junit_report_2026-08-30-06_18_47.xml"
            last = tmppath / "junit_report_2026-08-30-16_15_12.xml"
            reports = [
                {
                    "changed": [
                        {
                            "test": "suite / case_1",
                            "differences": {"status": {"first": "failure", "second": "passed"}},
                        },
                        {
                            "test": "suite / case_2",
                            "differences": {"status": {"first": "skipped", "second": "passed"}},
                        },
                    ]
                }
            ]

            out_file = mod.generate_explanation(first, last, reports)
            self.assertIsNotNone(out_file)
            self.assertTrue(out_file.exists())
            self.assertEqual(out_file.name, "explain_2026-08-30-06_18_47_2026-08-30-16_15_12.txt")

            content = out_file.read_text(encoding="utf-8")
            self.assertIn("Skutečně nestabilních (flaky) testů je 1", content)
            self.assertIn("částečně nestabilní testů je 1", content)
            self.assertIn("##Result for: Explanation and Analysis", content)


if __name__ == "__main__":
    unittest.main()

