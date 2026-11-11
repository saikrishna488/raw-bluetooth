"""Build a minimal LGPL FFmpeg; do not redistribute imageio's nonfree binary."""
import hashlib
from pathlib import Path
import subprocess
import shlex
import tarfile
import urllib.request

VERSION = '7.1.1'
SHA256 = '733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1'
FLAGS = ['--extra-cflags=-mmacosx-version-min=13.0', '--extra-ldflags=-mmacosx-version-min=13.0', '--disable-everything', '--disable-autodetect', '--disable-network',
         '--disable-x86asm', '--disable-debug', '--disable-doc', '--enable-ffmpeg',
         '--disable-ffplay', '--disable-ffprobe', '--enable-protocol=pipe,file',
         '--enable-indev=lavfi', '--enable-filter=sine,aformat,aresample,anull',
         '--enable-demuxer=wav,mp3,flac,mov',
         '--enable-parser=mpegaudio,flac,aac',
         '--enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,mp3float,flac,aac,alac', '--enable-encoder=sbc', '--enable-muxer=sbc', '--enable-swresample', '--enable-avfilter']


def build(folder):
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / f'ffmpeg-{VERSION}.tar.xz'
    if not archive.exists():
        urllib.request.urlretrieve(f'https://ffmpeg.org/releases/{archive.name}', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('FFmpeg source checksum mismatch')
    source = folder / f'ffmpeg-{VERSION}'
    if not source.exists():
        with tarfile.open(archive) as package:
            for member in package.getmembers():
                target = (folder / member.name).resolve()
                if not target.is_relative_to(folder.resolve()):
                    raise RuntimeError('Invalid FFmpeg source path')
            package.extractall(folder)
    executable = source / 'ffmpeg'
    existing = subprocess.check_output([executable, '-buildconf'], stderr=subprocess.STDOUT, text=True) if executable.exists() else ''
    if any(flag not in shlex.split(existing) for flag in FLAGS):
        subprocess.run(['./configure', *FLAGS], cwd=source, check=True)
        subprocess.run(['make', '-j4'], cwd=source, check=True)
    config = subprocess.check_output([executable, '-buildconf'], stderr=subprocess.STDOUT, text=True)
    if '--enable-gpl' in config or '--enable-nonfree' in config or '--enable-version3' in config:
        raise RuntimeError('Refusing a non-LGPL FFmpeg binary')
    subprocess.run([executable, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'sine=frequency=440:sample_rate=44100', '-t', '0.1', '-ac', '2',
                    '-ar', '44100', '-c:a', 'sbc', '-f', 'sbc', 'pipe:1'],
                   check=True, stdout=subprocess.DEVNULL)
    return executable, archive
