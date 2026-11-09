#!/usr/bin/env python3
"""Play a quiet temporary tone; verify actual tap callback metrics in the app bundle."""
import argparse
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import wave

parser = argparse.ArgumentParser()
parser.add_argument('binary', help='Path to the built macOS app executable')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='mvm-signal-') as directory:
    tone = Path(directory) / 'tone.wav'
    with wave.open(str(tone), 'wb') as stream:
        stream.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
        frame = b''.join(struct.pack('<hh', v, v) for i in range(48000) for v in [int(600 * math.sin(2 * math.pi * 440 * i / 48000))])
        for _ in range(15):
            stream.writeframes(frame)
    player = subprocess.Popen(['/usr/bin/afplay', str(tone)])
    try:
        time.sleep(.5)
        result = subprocess.run([args.binary, '--probe-mix=path:/usr/bin/afplay'], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stderr
        records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        for stage, expected in [('quarter', .25), ('mute', 0), ('half', .5)]:
            samples = [record['app'] for record in records if record['stage'] == stage]
            assert samples, (stage, result.stdout)
            last = samples[-1]
            assert last['controlled'] and last['callbackCount'] > 0 and last['inputRms'] > 1e-6, last
            ratio = last['outputRms'] / last['inputRms']
            assert abs(ratio - expected) < .005, last
            print('%s: output/input RMS = %.4f; callbacks = %d' % (stage, ratio, last['callbackCount']))
        assert records[-1]['stage'] == 'restored', records[-1]
        print('Original audio restore completed; no audio was recorded or saved by the mixer.')
    finally:
        player.terminate()
        player.wait()
