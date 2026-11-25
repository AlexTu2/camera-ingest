#!/usr/bin/env python3
"""Persist camera tags beside NAS media without modifying media or existing XMP."""
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET


def write_sidecars(root, entries):
    root = Path(root).resolve(strict=True)
    ns = {'x': 'adobe:ns:meta/',
          'rdf': 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
          'digiKam': 'http://www.digikam.org/ns/1.0/'}
    for prefix, uri in ns.items():
        ET.register_namespace(prefix, uri)
    created = existing = 0
    for entry in entries:
        relative = PurePosixPath(entry['relativePath'])
        if relative.is_absolute() or '..' in relative.parts or any(
                part.startswith('.') for part in relative.parts):
            raise ValueError(f'Unsafe media path: {relative}')
        media = (root / relative).resolve(strict=True)
        if not media.is_relative_to(root) or not media.is_file():
            raise ValueError(f'Media outside NAS root: {relative}')
        sidecar = Path(str(media) + '.xmp')
        # Respect both Immich naming conventions, including existing metadata.
        if sidecar.exists() or sidecar.is_symlink() or media.with_suffix('.xmp').exists():
            existing += 1
            continue
        xml = ET.Element('{%s}xmpmeta' % ns['x'])
        rdf = ET.SubElement(xml, '{%s}RDF' % ns['rdf'])
        description = ET.SubElement(rdf, '{%s}Description' % ns['rdf'],
                                    {'{%s}about' % ns['rdf']: ''})
        tags = ET.SubElement(description, '{%s}TagsList' % ns['digiKam'])
        seq = ET.SubElement(tags, '{%s}Seq' % ns['rdf'])
        for value in sorted(set(entry['tags'])):
            ET.SubElement(seq, '{%s}li' % ns['rdf']).text = value
        # O_EXCL also protects a sidecar created concurrently by another tool.
        try:
            fd = os.open(sidecar, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            existing += 1
            continue
        with os.fdopen(fd, 'wb') as stream:
            stream.write(ET.tostring(xml, encoding='utf-8', xml_declaration=True))
        created += 1
    return {'created': created, 'existing': existing}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--write':
        print(json.dumps(write_sidecars(sys.argv[2], json.load(sys.stdin))))
        return
    url = os.environ['IMMICH_URL'].rstrip('/')
    key = Path(os.environ['IMMICH_KEY_FILE']).read_text().strip()
    library = os.environ['IMMICH_LIBRARY_ID']
    prefix = PurePosixPath(os.environ.get('IMMICH_NAS_PREFIX', '/mnt/luna'))
    root_tag = os.environ.get('IMMICH_TAG_ROOT', 'Camera')

    def api(path, data=None, method=None):
        request = urllib.request.Request(
            url + '/api' + path, method=method,
            data=json.dumps(data).encode() if data is not None else None,
            headers={'x-api-key': key, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=120) as response:
            body = response.read()
            return json.loads(body) if body else None

    def search(**extra):
        page = 1
        while page:
            result = api('/search/metadata', {
                'libraryId': library, 'size': 1000, 'page': int(page),
                'withDeleted': False, **extra})['assets']
            yield from result['items']
            page = result.get('nextPage')

    entries = {}
    for asset in search():
        path = PurePosixPath(asset['originalPath'])
        if asset.get('visibility') == 'hidden' or not path.is_relative_to(prefix):
            continue
        if asset['type'] not in ('VIDEO', 'IMAGE'):
            continue
        relative = path.relative_to(prefix)
        tags = [root_tag + ('/Video' if asset['type'] == 'VIDEO' else '/Photo')]
        if str(path).startswith(os.environ.get('IMMICH_EDITED_PREFIX', '/mnt/luna/Edited/')):
            tags.append(root_tag + '/Edited')
        entries[asset['id']] = {'relativePath': str(relative), 'tags': tags}

    # Preserve other tags already attached to these assets in Immich.
    for tag in api('/tags'):
        for asset in search(tagIds=[tag['id']]):
            if asset['id'] in entries:
                entries[asset['id']]['tags'].append(tag['value'])

    command = shlex.join(['python3', '-c', Path(__file__).read_text(),
                          '--write', os.environ['NAS_FLATTEN_TO']])
    result = subprocess.run(
        ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20',
         os.environ['NAS_USER'] + '@' + os.environ['NAS_HOST'], command],
        input=json.dumps(list(entries.values())), text=True,
        capture_output=True, timeout=180, check=True)
    counts = json.loads(result.stdout)
    print(f"XMP sidecars: {counts['created']} created, {counts['existing']} preserved", flush=True)
    if counts['created']:
        # Unchanged external media needs sidecar discovery to link its new XMP.
        api('/jobs/sidecar', {'command': 'start', 'force': False}, 'PUT')
        print('Queued sidecar discovery for persistent tags', flush=True)


if __name__ == '__main__':
    main()
