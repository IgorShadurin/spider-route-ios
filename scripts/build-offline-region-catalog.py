#!/usr/bin/env python3
"""Build the region picker from pinned, public-domain Natural Earth GeoJSON."""
import argparse, hashlib, json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
records = []
sources = {}
with (args.output/'geometry.bin').open('wb') as stream:
    for level, name in [(0, 'ne_10m_admin_0_countries'), (1, 'ne_10m_admin_1_states_provinces')]:
        file = args.source/(name+'.geojson')
        sources[name] = hashlib.sha256(file.read_bytes()).hexdigest()
        for feature in json.loads(file.read_text())['features']:
            props = {k.lower(): v for k,v in feature['properties'].items()}
            country = props['adm0_a3']
            identifier = 'country.'+country if level == 0 else 'province.'+str(props['ne_id'])
            geometry = json.dumps(feature['geometry'], separators=(',', ':'), ensure_ascii=False).encode()
            offset = stream.tell(); stream.write(geometry)
            names = {k[5:]:v for k,v in props.items() if k.startswith('name_') and k[5:] in ['ar','bn','de','en','es','fa','fr','el','he','hi','hu','id','it','ja','ko','nl','pl','pt','ru','sv','tr','uk','ur','vi','zh','zht'] and isinstance(v,str) and v}
            # EH assigns the sovereign's ISO code to some separate dependencies.
            # Keep their own translated names instead of labeling every island Australia.
            if level == 1 and props.get('name') == 'City of Minsk': names['en'] = 'City of Minsk'
            records.append({'id':identifier, 'parentID':None if level == 0 else 'country.'+country,
                'countryCode':props.get('iso_a2',''), 'subdivisionCode':props.get('iso_3166_2') if level == 1 else None, 'name':props.get('name_en') or props.get('name') or props.get('admin'),
                'names':names, 'bounds':feature['bbox'], 'offset':offset, 'length':len(geometry)})
assert len({r['id'] for r in records}) == len(records)
ids={r['id'] for r in records}
assert all(r['parentID'] is None or r['parentID'] in ids for r in records)
(args.output/'catalog.json').write_text(json.dumps(records, separators=(',', ':'), ensure_ascii=False)+'\n')
(args.output/'SOURCE.json').write_text(json.dumps({'source':'https://github.com/nvkelso/natural-earth-vector',
    'commit':(args.source/'commit.txt').read_text().strip(), 'license':'Public domain',
    'license_url':'https://www.naturalearthdata.com/about/terms-of-use/', 'source_sha256':sources,
    'countries':sum(r['parentID'] is None for r in records), 'provinces':sum(r['parentID'] is not None for r in records),
    'geometry':'Original GeoJSON coordinates and rings, without simplification. Concatenated geometries are read by byte range.'},indent=2)+'\n')
print(len(records), 'regions;', (args.output/'geometry.bin').stat().st_size, 'geometry bytes')
