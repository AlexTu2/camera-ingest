import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location(
    'sidecars', Path(__file__).resolve().parents[1] / 'immich-sidecars.py')
sidecars = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sidecars)


class SidecarTests(unittest.TestCase):
    def test_creates_valid_tags_without_changing_media_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            media = Path(directory) / 'a & b.mp4'
            media.write_bytes(b'original video')
            entries = [{'relativePath': media.name,
                        'tags': ['Luna Ultra/Video', 'Custom & tag']}]
            self.assertEqual(sidecars.write_sidecars(directory, entries)['created'], 1)
            xmp = Path(str(media) + '.xmp')
            tags = ET.parse(xmp).findall('.//{http://www.w3.org/1999/02/22-rdf-syntax-ns#}li')
            self.assertEqual({tag.text for tag in tags}, set(entries[0]['tags']))
            before = xmp.read_bytes(), xmp.stat().st_mtime_ns
            self.assertEqual(sidecars.write_sidecars(directory, entries)['existing'], 1)
            self.assertEqual((xmp.read_bytes(), xmp.stat().st_mtime_ns), before)
            self.assertEqual(media.read_bytes(), b'original video')

    def test_preserves_existing_fallback_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            media = Path(directory) / 'photo.jpg'
            media.touch()
            old = media.with_suffix('.xmp')
            old.write_bytes(b'existing metadata, never rewrite')
            result = sidecars.write_sidecars(directory, [
                {'relativePath': media.name, 'tags': ['Luna Ultra/Photo']}])
            self.assertEqual(result, {'created': 0, 'existing': 1})
            self.assertFalse(Path(str(media) + '.xmp').exists())
            self.assertEqual(old.read_bytes(), b'existing metadata, never rewrite')

    def test_rejects_traversal_hidden_paths_and_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'root'
            root.mkdir()
            outside = Path(directory) / 'outside.mp4'
            outside.touch()
            (root / 'link.mp4').symlink_to(outside)
            for path in ['../outside.mp4', str(outside), '.incoming/a.mp4', 'link.mp4']:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    sidecars.write_sidecars(root, [{'relativePath': path, 'tags': ['Video']}])
            self.assertFalse(Path(str(outside) + '.xmp').exists())


if __name__ == '__main__':
    unittest.main()
