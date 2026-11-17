#!/usr/bin/env python3
"""Pinned local MiniFASNet evaluation conversion. No camera or user imagery is read."""
import hashlib
import importlib.util
import json
from pathlib import Path
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / 'Models'
SOURCE = MODELS / 'passive-pad-source'
REVISION = 'b6d5f04ad78778917853b25c778acef6d5626d15'
BASE = f'https://raw.githubusercontent.com/minivision-ai/Silent-Face-Anti-Spoofing/{REVISION}'
ASSETS = {
    'src/model_lib/MiniFASNet.py': 'e498c4ec5e1ddfaba62b941a126c19d65aa564999f3309661fe43ee8bf38acd7',
    'resources/anti_spoof_models/2.7_80x80_MiniFASNetV2.pth': 'a5eb02e1843f19b5386b953cc4c9f011c3f985d0ee2bb9819eea9a142099bec0',
    'resources/anti_spoof_models/4_0_0_80x80_MiniFASNetV1SE.pth': '84ee1d37d96894d5e82de5a57df044ef80a58be2b218b5ed7cdfd875ec2f5990',
    'LICENSE': 'daf94bf1dc9cc5700fe5af2c7c0cbd1836e70d509ed78fd0bebef7432edee6fb',
}
IDENTIFIER = 'minivision-minifasnet-pair-b6d5f04-fp32-v1'


def synthetic(seed):
    import numpy as np
    y, x = np.mgrid[0:80, 0:80]
    # Planar BGR, float32 0...255, without /255 normalization (matches upstream numpy path).
    return np.stack([(x*53+y*7+seed*47)%256, (x*11+y*43+seed*29)%256,
                     (x*37+y*17+seed*13)%256]).astype(np.float32)[None]


def main():
    for name, digest in ASSETS.items():
        path = SOURCE / name
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(urllib.request.urlopen(f'{BASE}/{name}').read())
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'Pinned source/weight mismatch: {name}')
    import numpy as np
    import torch
    import coremltools as ct
    torch.set_num_threads(2)
    spec = importlib.util.spec_from_file_location('pinned_minifas', SOURCE/'src/model_lib/MiniFASNet.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    nets = [module.MiniFASNetV2(conv6_kernel=(5, 5)), module.MiniFASNetV1SE(conv6_kernel=(5, 5))]
    names = list(ASSETS)[1:3]
    for net, name in zip(nets, names):
        weights = torch.load(SOURCE/name, map_location='cpu', weights_only=True)
        net.load_state_dict({key.removeprefix('module.'): value for key, value in weights.items()}, strict=True)
        net.eval()

    class Pair(torch.nn.Module):
        def __init__(self):
            super().__init__(); self.near = nets[0]; self.wide = nets[1]
        def forward(self, crop27, crop40):
            return torch.stack([torch.softmax(self.near(crop27), dim=1),
                                torch.softmax(self.wide(crop40), dim=1)], dim=1)

    pair = Pair().eval()
    inputs = (torch.from_numpy(synthetic(0)), torch.from_numpy(synthetic(1)))
    with torch.no_grad():
        traced = torch.jit.trace(pair, inputs)
    model = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
        inputs=[ct.TensorType(name='crop27', shape=(1, 3, 80, 80)), ct.TensorType(name='crop40', shape=(1, 3, 80, 80))],
        outputs=[ct.TensorType(name='probabilities')])
    model.short_description = 'Experimental passive PAD pair. Original BGR 0...255 crops, scales 2.7 and 4.0; live class index 1. Evaluation required.'
    model.author = 'Minivision (original weights); local Core ML conversion'
    model.license = 'Apache-2.0; see Minivision-Apache-LICENSE.txt'
    model.user_defined_metadata['modelIdentifier'] = IDENTIFIER
    model.user_defined_metadata['sourceRevision'] = REVISION
    model.save(str(MODELS/'PassivePAD.mlpackage'))
    cases, durations = [], []
    for seed in [0, 1, 7, 19, 113]:
        a, b = synthetic(seed), synthetic(seed+1)
        with torch.no_grad(): expected = pair(torch.from_numpy(a), torch.from_numpy(b)).numpy()
        started = time.perf_counter()
        actual = np.asarray(model.predict({'crop27': a, 'crop40': b})['probabilities'])
        durations.append((time.perf_counter()-started)*1000)
        error = float(np.max(np.abs(actual-expected)))
        assert actual.shape == (1, 2, 3) and np.isfinite(actual).all() and error < 0.001, error
        cases.append({'seed': seed, 'probabilities': expected.reshape(-1).tolist()})
        print(f'seed={seed}: max prediction difference {error:.8f}', flush=True)
    reference = {'schema': 1, 'modelIdentifier': IDENTIFIER, 'maximumAbsoluteError': 0.001, 'cases': cases}
    (MODELS/'PassivePADReference.json').write_text(json.dumps(reference, indent=2)+'\n')
    (MODELS/'Minivision-Apache-LICENSE.txt').write_bytes((SOURCE/'LICENSE').read_bytes())
    files = []
    for path in sorted((MODELS/'PassivePAD.mlpackage').rglob('*')):
        if path.is_file(): files.append({'path': str(path.relative_to(MODELS)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    for name in ['PassivePADReference.json', 'Minivision-Apache-LICENSE.txt']:
        files.append({'path': name, 'sha256': hashlib.sha256((MODELS/name).read_bytes()).hexdigest()})
    provenance = {'schema': 1, 'modelIdentifier': IDENTIFIER, 'sourceRevision': REVISION,
                  'upstream': [{'path': name, 'url': f'{BASE}/{name}', 'sha256': digest} for name, digest in ASSETS.items()],
                  'input': 'two planar BGR float32 tensors, 1x3x80x80, raw 0...255, crops at 2.7 and 4.0',
                  'output': '1x2x3 softmax distributions; class 1 is live for each model',
                  'torch': torch.__version__, 'coremltools': ct.__version__, 'files': files}
    (MODELS/'passive-pad-provenance.lock.json').write_text(json.dumps(provenance, indent=2)+'\n')
    (MODELS/'passive-pad-validation.json').write_text(json.dumps({'syntheticPredictionsMatch': True,
        'measuredMilliseconds': durations, 'note': 'Conversion mechanics only. Does not establish genuine/spoof accuracy.'}, indent=2)+'\n')
    print('Passive PAD pair converted and synthetic predictions validated.', flush=True)

if __name__ == '__main__': main()
