import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/fix-qt612-palette.py'
spec = importlib.util.spec_from_file_location('palette_fix', SCRIPT)
fix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fix)


class PaletteFixTest(unittest.TestCase):
    def test_backups_preview_and_idempotency(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'shell'
            commons = root / 'Commons'
            commons.mkdir(parents=True)
            (commons / 'qmldir').write_text('singleton Color 1.0 Color.qml\n')
            files = {
                root / 'Bar.qml': 'import QtQuick\nimport qs.Commons\nItem { property color fg: Color.bar.text }\n',
                commons / 'Style.qml': 'pragma Singleton\nimport QtQuick\nQtObject { property color fg: Color.foreground }\n',
                root / 'Fixed.qml': 'import QtQuick\nimport qs.Commons as Commons\nItem { property color fg: Commons.Color.bar.text }\n',
                root / 'Unrelated.qml': 'import QtQuick\nItem { property color fg: Color.rgba(1, 0, 0, 1) }\n',
            }
            for path, text in files.items(): path.write_text(text)
            subprocess.run([sys.executable, str(SCRIPT), str(root)], check=True, capture_output=True)
            for path, text in files.items(): self.assertEqual(path.read_text(), text)
            backup = Path(tmp) / 'backup'
            command = [sys.executable, str(SCRIPT), str(root), '--apply', '--backup-dir', str(backup)]
            subprocess.run(command, check=True, capture_output=True)
            for path in (root / 'Bar.qml', commons / 'Style.qml'):
                self.assertIn('CachyOmarchyPalette.Color.', path.read_text())
                self.assertEqual((backup / path.relative_to(root)).read_text(), files[path])
            for name in ('Fixed.qml', 'Unrelated.qml'):
                self.assertEqual((root / name).read_text(), files[root / name])
            result = subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertIn('Patched 0 file(s)', result.stdout)

    def test_alias_conflict_is_rejected(self):
        text = 'import qs.Commons\nimport Other as CachyOmarchyPalette\nItem { color: Color.bar.text }'
        with self.assertRaises(ValueError): fix.patched_text(Path('Bar.qml'), text)


if __name__ == '__main__':
    unittest.main()
