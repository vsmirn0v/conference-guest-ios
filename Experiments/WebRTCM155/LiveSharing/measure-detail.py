#!/usr/bin/env python3
"""Measure aligned static text detail in this harness's synthetic images.

Reports a luminance PSNR value, not a claim about full Presenter/UI acceptance.
Requires Pillow; no NumPy, network access or private source material.
"""
import argparse
import json
import math
from pathlib import Path
from PIL import Image, ImageChops, ImageStat


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    results = json.loads((args.directory / 'results.json').read_text())
    detail = []
    for phase in results['phases']:
        name = phase['phase']
        reference = Image.open(args.directory / f'reference-{name}.png').convert('L')
        decoded = Image.open(args.directory / f'decoded-{name}.png').convert('L')
        if reference.size != decoded.size:
            raise ValueError(f'{name}: source/decoded dimensions differ')
        width, height = reference.size
        crop = (32, 100, min(width - 30, 1100), min(height - 140, 650))
        error = ImageStat.Stat(ImageChops.difference(reference.crop(crop), decoded.crop(crop))).rms[0]
        row = {'phase': name, 'width': width, 'height': height,
               'cropPixels': crop, 'textLumaRMSE': error,
               'textLumaPSNRdB': 20 * math.log10(255 / error) if error else None,
               'exactLumaMatch': error == 0,
               'compositionCardPass': phase['compositionCardPass']}
        if 'detailOCRPass' in phase:
            row['headingOCRPass'] = phase['detailOCRPass']
        else:
            row.update(imageVerificationMethod=phase['imageVerification']['method'],
                       detailRasterPass=phase['detailRasterPass'],
                       headingRasterPass=phase['imageVerification']['headingRasterPass'],
                       phaseMarkerPass=phase['phaseMarkerPass'])
        detail.append(row)
    print(json.dumps({'scope': 'Aligned synthetic text-region luminance fidelity', 'phases': detail}, indent=2))


if __name__ == '__main__':
    main()
