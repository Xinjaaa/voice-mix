#!/usr/bin/env python3
"""Read-only by default; --write-device briefly changes volume and restores it."""
import argparse
import ctypes
import json
import math

parser = argparse.ArgumentParser()
parser.add_argument('library')
parser.add_argument('--write-device', action='store_true')
args = parser.parse_args()
lib = ctypes.CDLL(args.library)
lib.mvm_create.restype = ctypes.c_void_p
lib.mvm_execute.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.mvm_execute.restype = ctypes.c_void_p
lib.mvm_free.argtypes = [ctypes.c_void_p]
lib.mvm_destroy.argtypes = [ctypes.c_void_p]
context = lib.mvm_create()

def execute(request):
    pointer = lib.mvm_execute(context, json.dumps(request).encode())
    assert pointer, 'Native response missing'
    try:
        return json.loads(ctypes.string_at(pointer))
    finally:
        lib.mvm_free(pointer)

try:
    snapshot = execute({'op': 'snapshot'})
    assert snapshot['ok'], snapshot
    devices = snapshot['data']['devices']
    assert devices, 'No audio devices detected'
    print('Detected %d device directions, %d active audio applications' % (len(devices), len(snapshot['data']['apps'])))
    for request in [{'op': 'unknown'}, {'op': 'device_volume', 'uid': 'missing', 'direction': 'output', 'volume': .4}, {'op': 'device_volume', 'uid': devices[0]['uid'], 'direction': 'invalid', 'volume': .4}]:
        result = execute(request)
        assert not result['ok'], result
    for direction in ['input', 'output']:
        device = next((d for d in devices if d['direction'] == direction and d['isDefault'] and d['canSetVolume']), None)
        if device and args.write_device:
            original = device['volume']
            target = max(0, original - .03)
            try:
                result = execute({'op': 'device_volume', 'uid': device['uid'], 'direction': direction, 'volume': target})
                assert result['ok'], result
                actual = next(d for d in result['data']['devices'] if d['id'] == device['id'])['volume']
                assert math.isclose(actual, target, abs_tol=.025), (actual, target)
                print('%s write/read confirmed: %.4f -> %.4f' % (direction, original, actual))
            finally:
                restored = execute({'op': 'device_volume', 'uid': device['uid'], 'direction': direction, 'volume': original})
                assert restored['ok'], restored
                actual = next(d for d in restored['data']['devices'] if d['id'] == device['id'])['volume']
                assert math.isclose(actual, original, abs_tol=.025), (actual, original)
                print('%s restored: %.4f' % (direction, actual))
    assert execute({'op': 'restore'})['ok']
    assert execute({'op': 'shutdown'})['ok']
    assert execute({'op': 'shutdown'})['ok']
    print('Native snapshot, invalid arguments and repeated shutdown passed')
finally:
    lib.mvm_destroy(context)
