"""Build the C++ HID extension for the running Python interpreter."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import sysconfig
import shutil

ROOT = Path(__file__).resolve().parent.parent


def build():
    output = ROOT / ('_hid_native' + sysconfig.get_config_var('EXT_SUFFIX'))
    compiler = shlex.split(os.environ.get('CXX', 'c++'))
    temporary_hid = output.with_suffix(output.suffix + '.new')
    command = compiler + ['-std=c++17', '-O3', '-Wall', '-Wextra', '-Wno-missing-field-initializers',
                          '-shared', '-fPIC', '-I' + sysconfig.get_path('include'),
                          str(ROOT / 'native/hid.cpp'), '-o', str(temporary_hid)]
    if sys.platform == 'darwin':
        command += ['-undefined', 'dynamic_lookup', '-mmacosx-version-min=13.0']
    subprocess.run(command, check=True)
    temporary_hid.replace(output)
    if sys.platform != 'darwin':
        raise RuntimeError('The driver backend targets macOS; only HID is portable.')
    import libusb_package
    folder = ROOT / 'build/native'
    folder.mkdir(parents=True, exist_ok=True)
    library = folder / 'libusb-1.0.dylib'
    temporary_library = folder / 'libusb-1.0.new.dylib'
    shutil.copy2(libusb_package.get_library_path(), temporary_library)
    subprocess.run(['install_name_tool', '-id', '@rpath/libusb-1.0.dylib', str(temporary_library)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(temporary_library)], check=True)
    temporary_library.replace(library)
    backend = ROOT / ('_driver_native' + sysconfig.get_config_var('EXT_SUFFIX'))
    native_command = compiler + ['-std=c++17', '-O2', '-Wall', '-Wextra', '-Wno-missing-field-initializers',
                                 '-mmacosx-version-min=13.0',
                                 '-I' + str(ROOT / 'native'), '-L' + str(folder), '-lusb-1.0',
                                 '-framework', 'IOKit', '-framework', 'CoreFoundation',
                                 '-framework', 'ApplicationServices']
    temporary = backend.with_suffix(backend.suffix + '.new')
    subprocess.run(native_command + ['-shared', '-fPIC', '-undefined', 'dynamic_lookup',
                                    '-I' + sysconfig.get_path('include'), str(ROOT / 'native/driver.cpp'),
                                    '-Wl,-rpath,@loader_path/build/native', '-o', str(temporary)], check=True)
    temporary.replace(backend)
    broker = folder / 'raw-bluetooth-usb'
    temporary_broker = folder / 'raw-bluetooth-usb.new'
    subprocess.run(native_command + [str(ROOT / 'native/usb_service.cpp'),
                                    '-Wl,-rpath,@loader_path', '-o', str(temporary_broker)], check=True)
    temporary_broker.replace(broker)
    subprocess.run(['codesign', '--force', '--sign', '-', str(broker)], check=True)
    return output


if __name__ == '__main__':
    print(build())
