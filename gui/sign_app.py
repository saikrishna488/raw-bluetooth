"""Sign local builds with a stable, dedicated development certificate.

The private identity lives in a separate local keychain, not the login keychain.
The certificate's local trust policy is limited to code signing.
"""
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FOLDER = ROOT / '.signing'
NAME = 'Raw Bluetooth Local Development'


def run(args, data=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Never include argv: keychain commands contain the local password.
        raise RuntimeError(f'{Path(args[0]).name} {args[1]} failed: {result.stderr.decode(errors="replace")[:800]}')
    return result.stdout


def sign(app):
    os.umask(0o077)
    FOLDER.mkdir(mode=0o700, exist_ok=True)
    password_file = FOLDER / 'keychain-password'
    if not password_file.exists():
        password_file.write_text(secrets.token_urlsafe(32))
    password = password_file.read_text().strip()
    keychain = str(FOLDER / 'rawbluetooth.keychain-db')
    certificate = FOLDER / 'certificate.pem'
    if not certificate.exists():
        config = FOLDER / 'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=signing\nprompt=no\n[dn]\nCN=' + NAME + '\n[signing]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
        run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-x509', '-days', '3650', '-config', str(config), '-keyout', str(FOLDER / 'private.pem'), '-out', str(certificate)])
        run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(FOLDER / 'private.pem'), '-in', str(certificate), '-out', str(FOLDER / 'identity.p12'), '-passout', 'stdin'], (password + '\n').encode())
        run(['/usr/bin/security', 'create-keychain', '-p', password, keychain])
        run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
        run(['/usr/bin/security', 'import', str(FOLDER / 'identity.p12'), '-k', keychain, '-P', password, '-T', '/usr/bin/codesign'])
        run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain])
        (FOLDER / 'private.pem').unlink()
        (FOLDER / 'identity.p12').unlink()
    run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
    try:
        run(['/usr/bin/security', 'verify-cert', '-p', 'codeSign', '-c', str(certificate)])
    except RuntimeError:
        run(['/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign', '-k', keychain, str(certificate)])
    der = run(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-outform', 'DER'])
    fingerprint = hashlib.sha1(der).hexdigest()
    requirement = f'=designated => identifier "local.rawbluetooth.desktop" and certificate leaf = H"{fingerprint}"'
    search_list = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode())
    try:
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search_list, keychain])
        run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', keychain, '--identifier', 'local.rawbluetooth.desktop', '--requirements', requirement, str(app)])
    finally:
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search_list])
    run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
    print('Signed with stable local development identity')


if __name__ == '__main__':
    sign(Path(sys.argv[1]))
