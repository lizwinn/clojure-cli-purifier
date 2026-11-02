#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise native locking and execution with a Nix-provided JVM module."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(
    ['nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(
    ['nix', 'flake', 'metadata', '--json', '--no-write-lock-file', 'path:' + str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix="purifier-native-composition-") as temporary:
    temporary = Path(temporary)
    package = subprocess.check_output(
        ['nix', 'build', str(root) + '#default', '--print-out-paths',
         '--out-link', str(temporary / 'cli')], text=True).strip().splitlines()[-1]
    cli = Path(package) / 'bin/clojure-cli-purifier'
    workspace = temporary / 'project'
    shutil.copytree(root / 'tests/fixtures/hello', workspace)
    (workspace / 'clojure-cli-purifier.lock.json').unlink(missing_ok=True)
    reference='path:'+snapshot+'#checks.'+system+'.composition.provider'
    def run(*args):
        subprocess.run([str(x) for x in args],cwd=workspace,check=True)
    run(cli,'lock','--input',reference,'--test','-M:test','--test','-M:range','--test','-M:snapshot')
    locked=json.loads((workspace/'clojure-cli-purifier.lock.json').read_text())
    assert len(locked['projectInputs'])==1
    assert not any(entry['path'].startswith('org/clojure/data.json/') for entry in locked['artifacts'])
    run(cli,'prefetch')
    run(workspace/'.clojure-cli-purifier/bin/clojure','-M:test')
    run(workspace/'.clojure-cli-purifier/bin/clojure','-T:build','jar')
    print('CLOJURE NATIVE ROUNDTRIP PASSED')
