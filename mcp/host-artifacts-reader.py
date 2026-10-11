#!/usr/bin/env python3
"""Stream approved sources using descriptor-relative, no-follow opens.

Python exposes openat on both macOS and Linux; Node does not. No directory
component in a canonical path is ever followed as a symlink during an open.
"""
import base64
import json
import os
import stat
import sys


def inside(candidate, root):
    return os.path.commonpath([candidate, root]) == root


def open_absolute(filename):
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        parts = filename.split('/')[1:]
        for index, part in enumerate(parts):
            if not part:
                continue
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if index != len(parts) - 1:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def emit(message):
    print(json.dumps(message, ensure_ascii=True), flush=True)


def stream(descriptor, canonical, root, relative, ancestors, forbidden):
    before = os.fstat(descriptor)
    identity = (before.st_dev, before.st_ino)
    if stat.S_ISDIR(before.st_mode):
        if forbidden and inside(forbidden, canonical):
            raise ValueError('Cannot import a directory containing the artifact destination')
        if identity in ancestors:
            raise ValueError('Source directory contains a symlink cycle')
        if relative:
            emit({'op': 'directory', 'path': relative})
        for name in sorted(os.listdir(descriptor)):
            if name in ('.', '..') or any(ord(c) < 32 or ord(c) == 127 or c == '\\' for c in name):
                raise ValueError('Invalid artifact source path')
            filename = os.path.join(canonical, name)
            entry = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISLNK(entry.st_mode):
                filename = os.path.realpath(filename)
                if not inside(filename, root):
                    raise ValueError('Source symlink escapes the authorized directory')
                child = open_absolute(filename)
            else:
                child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                dir_fd=descriptor)
            try:
                stream(child, filename, root, '/'.join(filter(None, [relative, name])),
                       ancestors | {identity}, forbidden)
            finally:
                os.close(child)
    elif stat.S_ISREG(before.st_mode):
        emit({'op': 'file', 'path': relative, 'size': before.st_size})
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                raise ValueError('Source changed during import')
            remaining -= len(chunk)
            emit({'op': 'data', 'data': base64.b64encode(chunk).decode('ascii')})
        after = os.fstat(descriptor)
        if after.st_size != before.st_size or after.st_mtime_ns != before.st_mtime_ns:
            raise ValueError('Source changed during import')
        emit({'op': 'end-file'})
    else:
        raise ValueError('Source contains an unsupported filesystem object')


def main(options):
    source, root = options['source'], options['root']
    canonical = os.path.realpath(source)
    if not inside(canonical, root):
        raise ValueError('Source symlink escapes the authorized directory')
    descriptor = open_absolute(canonical)
    try:
        expected = options.get('expectedKind')
        mode = os.fstat(descriptor).st_mode
        if expected and not (stat.S_ISREG(mode) if expected == 'file' else stat.S_ISDIR(mode)):
            raise ValueError('Source type changed during import')
        stream(descriptor, canonical, root, options.get('relative', ''), set(),
               options.get('forbiddenDirectory'))
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    try:
        main(json.loads(sys.argv[1]))
    except Exception as error:
        print('Safe host artifact read failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
