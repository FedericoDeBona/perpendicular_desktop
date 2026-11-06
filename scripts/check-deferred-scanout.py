#!/usr/bin/env python3
"""Compile the actual QEMU selection/tick code against controlled boundaries."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.read_text()
    state = source[source.index('static struct {'):source.index('static QEMUTimer *timer;')]
    body = source[source.index('static void tick(void *opaque)'):source.index('char *perp_live_qemu_stats(void)')]
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'qemu-deferred-selection.inc').write_text(state + body)
    test = Path(__file__).resolve().parents[1] / 'graphics/monitor/check-deferred-selection.c'
    binary = args.output / 'check'
    subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-I', str(args.output), str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
