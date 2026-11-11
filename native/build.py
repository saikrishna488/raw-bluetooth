"""Build the C++ HID extension for the running Python interpreter."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import sysconfig

ROOT = Path(__file__).resolve().parent.parent


def build():
    output = ROOT / ('_hid_native' + sysconfig.get_config_var('EXT_SUFFIX'))
    compiler = shlex.split(os.environ.get('CXX', 'c++'))
    command = compiler + ['-std=c++17', '-O3', '-Wall', '-Wextra', '-Wno-missing-field-initializers',
                          '-shared', '-fPIC', '-I' + sysconfig.get_path('include'),
                          str(ROOT / 'native/hid.cpp'), '-o', str(output)]
    if sys.platform == 'darwin':
        command += ['-undefined', 'dynamic_lookup']
    subprocess.run(command, check=True)
    return output


if __name__ == '__main__':
    print(build())
