#!/usr/bin/env python3
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('moodle_backup_progress', Path(__file__).resolve().parents[1] / 'backup/moodle_backup.py')
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class ProgressTests(unittest.TestCase):
    def test_direction(self):
        self.assertEqual(module.transfer_direction('/tmp/backup', 'gdrive:backup'), 'Upload')
        self.assertEqual(module.transfer_direction('gdrive:backup', '/tmp/backup'), 'Download')
        self.assertEqual(module.transfer_direction('a:backup', 'b:backup'), 'Transfer')

    def test_transfer_message_and_unknown_total(self):
        run = module.BackupRun.__new__(module.BackupRun)
        run.header, run.body_lines, run.tg = '', [], Mock()
        callback = run.make_progress_cb('School <A>', 'Download')
        callback('label', 1024, 2048, 512, 2, 0, 1, 2)
        text = run.tg.edit.call_args.args[0]
        self.assertIn('School &lt;A&gt;', text)
        self.assertIn('50.0%', text)
        self.assertIn('Download speed: 512.0B/s', text)
        self.assertIn('ETA: 2s', text)
        callback('label', 1024, 0, 512, None, 0, 1, 0)
        text = run.tg.edit.call_args.args[0]
        self.assertIn('Transferred: 1.0KB', text)
        self.assertNotIn('%', text)

    def test_failed_edit_is_throttled(self):
        telegram = module.Telegram('test', 'test', Mock(), edit_interval=1)
        telegram.message_id = 1
        with patch.object(module.time, 'time', return_value=100), patch.object(
            module.urllib.request, 'urlopen', side_effect=OSError('offline')
        ) as request:
            telegram.edit('first')
            telegram.edit('second')
            self.assertEqual(request.call_count, 1)
        self.assertEqual(telegram.edit_interval, 15)

    def test_telegram_retry_after(self):
        telegram = module.Telegram('test', 'test', Mock())
        telegram.message_id = 1
        error = module.urllib.error.HTTPError('https://example.invalid', 429, 'limited', {},
            io.BytesIO(b'{"parameters":{"retry_after":60}}'))
        with patch.object(module.time, 'time', return_value=100), patch.object(
            module.urllib.request, 'urlopen', side_effect=error
        ) as request:
            telegram.edit('first')
            with patch.object(module.time, 'time', return_value=130):
                telegram.edit('second')
            self.assertEqual(request.call_count, 1)


if __name__ == '__main__':
    unittest.main()
