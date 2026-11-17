import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

path = Path(__file__).with_name('record-process-samples.py')
spec = importlib.util.spec_from_file_location('record_process_samples', path)
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class ProcessSampleTests(unittest.TestCase):
    def test_selects_only_installed_app(self):
        def run(args, **kwargs):
            if args[0] == 'pgrep':
                return SimpleNamespace(stdout='100\n101\n')
            command = str(recorder.EXECUTABLE) if args[2] == '100' else '/tmp/unrelated-test-host'
            return SimpleNamespace(stdout=command + '\n')
        with patch.object(recorder.subprocess, 'run', side_effect=run):
            self.assertEqual(recorder.installed_process(), 100)

    def test_refuses_ambiguous_processes(self):
        def run(args, **kwargs):
            return SimpleNamespace(stdout=('100\n101\n' if args[0] == 'pgrep' else str(recorder.EXECUTABLE) + '\n'))
        with patch.object(recorder.subprocess, 'run', side_effect=run):
            with self.assertRaises(RuntimeError):
                recorder.installed_process()

    def test_sample_converts_rss_and_refuses_missing_process(self):
        with patch.object(recorder.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='12.5 2048\n')):
            self.assertEqual(recorder.sample(100), {'cpuPercent': 12.5, 'residentMiB': 2.0})
        with patch.object(recorder.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='')):
            with self.assertRaises(RuntimeError):
                recorder.sample(100)


if __name__ == '__main__':
    unittest.main()
