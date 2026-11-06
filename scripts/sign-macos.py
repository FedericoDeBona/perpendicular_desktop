#!/usr/bin/env python3
"""Persistent per-Mac development signing; private identity never enters Git.

No trust-store or TCC changes. Missing/partial identities are never rotated.
Use --setup once on each Mac, then --app at the end of every build.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile

ROOT = Path.home() / 'Library/Application Support/Perpendicular Signing'
KEYCHAIN = ROOT / 'development.keychain-db'
PASSWORD = ROOT / 'keychain-password'
CERT = ROOT / 'certificate.der'
IDENTIFIER = 'com.perpendicular.restart'


def run(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if result.returncode:
        # Arguments to security can contain secrets; never echo the command.
        raise RuntimeError(f'{Path(args[0]).name} failed: {result.stderr.strip()}')
    return result.stdout


def requirement():
    for path in (ROOT, KEYCHAIN, PASSWORD, CERT):
        if path.is_symlink() or not path.exists() or path.stat().st_uid != os.getuid():
            raise RuntimeError('Local signing identity missing/unsafe. Run scripts/sign-macos.py --setup; never replace an existing identity.')
    if ROOT.stat().st_mode & 0o077 or PASSWORD.stat().st_mode & 0o077:
        raise RuntimeError('Signing directory/password must be private (0700/0600).')
    run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', CERT, '-checkend', '0', '-noout'])
    fingerprint = hashlib.sha1(CERT.read_bytes()).hexdigest().upper()
    return fingerprint, f'identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'


def sign_component(path, identifier):
    """Give packaged file/network helpers the same persistent per-Mac identity."""
    if not identifier.startswith(IDENTIFIER + '.') or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in identifier):
        raise ValueError('Invalid companion signing identifier')
    fingerprint, _ = requirement()
    expected = f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'
    run(['/usr/bin/security', 'unlock-keychain', '-p', PASSWORD.read_text(), KEYCHAIN])
    run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', KEYCHAIN,
         '--timestamp=none', '--identifier', identifier, '--requirements', '=designated => '+expected, path])
    run(['/usr/bin/codesign', '--verify', '--strict', '-R', '='+expected, path])


def setup():
    if ROOT.exists():
        requirement()
        print('Existing local signing identity retained.')
        return
    ROOT.mkdir(mode=0o700, parents=True)
    password = secrets.token_hex(32)
    PASSWORD.write_text(password)
    PASSWORD.chmod(0o600)
    # security create-keychain may add to the user's search list; restore it.
    import shlex
    search = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
    try:
        run(['/usr/bin/security', 'create-keychain', '-p', password, KEYCHAIN])
    finally:
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search])
    with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
        temp = Path(temporary)
        config = temp / 'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Perpendicular Local Development\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
        run(['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650', '-config', config, '-keyout', temp/'key.pem', '-out', temp/'cert.pem'])
        run(['/usr/bin/openssl', 'x509', '-in', temp/'cert.pem', '-outform', 'DER', '-out', CERT])
        run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', temp/'key.pem', '-in', temp/'cert.pem', '-out', temp/'identity.p12', '-passout', 'pass:'+password])
        run(['/usr/bin/security', 'import', temp/'identity.p12', '-k', KEYCHAIN, '-P', password, '-T', '/usr/bin/codesign'])
        run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, KEYCHAIN])
    print('Created private local development identity (not a distribution certificate).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--setup', action='store_true')
    parser.add_argument('--app', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.setup:
        setup()
    fingerprint, expected = requirement()
    if args.app:
        info = plistlib.loads((args.app/'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != IDENTIFIER:
            raise RuntimeError('Refusing to sign a different application identifier.')
        run(['/usr/bin/security', 'unlock-keychain', '-p', PASSWORD.read_text(), KEYCHAIN])
        run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', KEYCHAIN, '--timestamp=none', '--requirements', '=designated => '+expected, args.app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '='+expected, args.app])
        result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(args.app)], capture_output=True, text=True, check=True)
        actual = result.stdout + result.stderr
        if 'cdhash' in actual or fingerprint not in actual.upper():
            raise RuntimeError('Build did not retain the persistent certificate requirement.')
        print('Signed and verified with persistent local certificate: '+fingerprint)
    elif args.check:
        print('Persistent local signing identity ready: '+fingerprint)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(str(error))
