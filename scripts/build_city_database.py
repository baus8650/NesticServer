"""Offline country/region/city names from DB-IP Lite; coordinates are discarded.
CC BY 4.0: https://db-ip.com/db/lite.php
"""
import csv,gzip,io,ipaddress,pathlib,hashlib,sys,subprocess,json
SOURCE='https://download.db-ip.com/free/dbip-city-lite-2026-10.csv.gz'
raw=pathlib.Path(sys.argv[1]).read_bytes() if len(sys.argv)>1 else subprocess.check_output(['curl','--fail','--location','--silent','--show-error',SOURCE])
assert hashlib.sha256(raw).hexdigest()=='d0a4d9446c1e5b826b95f99ed3b3ce151b9844df0044fe223a636cde26c75f2a','City database checksum mismatch'
root=pathlib.Path(__file__).resolve().parents[1]/'Resources';root.mkdir(exist_ok=True)
locations=[{'country':None,'region':None,'city':None}];ids={};next_start={4:0,6:0}
files={v:(root/f'geoip-city-v{v}.bin').open('wb') for v in [4,6]}
try:
 for row in csv.reader(io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(raw)),encoding='utf-8')):
  start,end,continent,country,region,city,latitude,longitude=row
  first,last=ipaddress.ip_address(start),ipaddress.ip_address(end);v=first.version;width=4 if v==4 else 16
  a,b=int(first),int(last)
  assert a>=next_start[v],'Unsorted/overlapping location ranges'
  if a>next_start[v]:files[v].write((a-1).to_bytes(width,'big')+(0).to_bytes(4,'big'))
  key=(country,region,city)
  if key not in ids:ids[key]=len(locations);locations.append({'country':country if country!='ZZ' else None,'region':region or None,'city':city or None})
  files[v].write(b.to_bytes(width,'big')+ids[key].to_bytes(4,'big'));next_start[v]=b+1
 for v,f in files.items():
  width=4 if v==4 else 16;maximum=(1<<(width*8))-1
  if next_start[v]<=maximum:f.write(maximum.to_bytes(width,'big')+(0).to_bytes(4,'big'))
finally:
 for f in files.values():f.close()
(root/'geoip-locations.json').write_text(json.dumps(locations,ensure_ascii=False,separators=(',',':')))
(root/'GEOIP-LICENSE.txt').write_text('IP Geolocation by DB-IP: https://db-ip.com\nDB-IP Country Lite and City Lite, October 2026. CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\nConverted to name-only binary indexes by Nestic. Latitude and longitude discarded. Reduced-accuracy IP estimates; VPNs and relays can differ from actual location.\n')
print('Built offline city-name indexes:',len(locations),'locations; coordinates discarded.')
