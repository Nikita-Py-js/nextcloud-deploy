#!/usr/bin/env python3
"""Filesystem-backed OCC double; only for isolated idempotency tests."""
import json
import os
import sys
from pathlib import Path

path = Path(os.environ['OCC_TEST_STATE'])
state = json.loads(path.read_text()) if path.exists() else {
    'signaling': [], 'turn': [], 'stun': [], 'commands': [],
}
args = sys.argv[1:]
cmd = args[0]
state['commands'].append(cmd)
if cmd == 'app:list':
    print(json.dumps({'enabled': {'spreed': 'test'}, 'disabled': {}}))
elif cmd == 'app:enable':
    pass
elif cmd == 'talk:signaling:list':
    print(json.dumps(state['signaling']))
elif cmd == 'talk:turn:list':
    print(json.dumps(state['turn']))
elif cmd == 'talk:stun:list':
    print(json.dumps(state['stun']))
elif cmd == 'talk:signaling:delete':
    if not isinstance(state['signaling'], dict):
        state['signaling'] = {'servers': [], 'secret': ''}
    state['signaling']['servers'] = [s for s in state['signaling']['servers'] if s['server'] != args[1]]
elif cmd == 'talk:signaling:add':
    assert args[1] == '--verify'
    state['signaling']['servers'].append({'server': args[2], 'verify': True})
    state['signaling']['secret'] = args[3]
elif cmd == 'talk:turn:delete':
    scheme, server, protocols = args[1:]
    state['turn'] = [s for s in state['turn'] if (s['schemes'], s['server'], s['protocols']) != (scheme, server, protocols)]
elif cmd == 'talk:turn:add':
    assert args[1] == '--secret'
    secret, scheme, server, protocols = args[2:]
    assert not any((s['schemes'], s['server'], s['protocols']) == (scheme, server, protocols) for s in state['turn'])
    state['turn'].append({'schemes': scheme, 'server': server, 'protocols': protocols, 'secret': secret})
elif cmd == 'talk:stun:add':
    assert args[1] not in state['stun']
    state['stun'].append(args[1])
else:
    raise RuntimeError('Unexpected mock OCC command: ' + cmd)
path.write_text(json.dumps(state))
