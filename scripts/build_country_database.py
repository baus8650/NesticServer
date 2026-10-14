"""Build an offline country index. No visitor data is sent to the publisher.
DB-IP Country Lite is CC BY 4.0: https://db-ip.com/db/lite.php
"""
import csv,gzip,io,ipaddress,pathlib,urllib.request,hashlib,sys,subprocess
SOURCE='https://download.db-ip.com/free/dbip-country-lite-2026-10.csv.gz'
raw=pathlib.Path(sys.argv[1]).read_bytes() if len(sys.argv)>1 else subprocess.check_output(["curl","--fail","--location","--silent","--show-error",SOURCE])
assert hashlib.sha256(raw).hexdigest()=='097426b8ddae89157d444a59ac1847e873f7943c32d52becc4371c8b0273af80', 'Country database checksum mismatch' 
root=pathlib.Path(__file__).resolve().parents[1]/'Resources';root.mkdir(exist_ok=True)
rows={4:[],6:[]}
for start,end,country in csv.reader(io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(raw)),encoding='utf-8')):
 first,last=ipaddress.ip_address(start),ipaddress.ip_address(end)
 rows[first.version].append((int(first),int(last),country))
for version,values in rows.items():
 width=4 if version==4 else 16
 with (root/f'geoip-country-v{version}.bin').open('wb') as f:
  next_start=0
  for first,last,country in sorted(values):
   if first>next_start:f.write((first-1).to_bytes(width,'big')+b'ZZ')
   f.write(last.to_bytes(width,'big')+country.encode('ascii'));next_start=last+1
  maximum=(1<<(width*8))-1
  if next_start<=maximum:f.write(maximum.to_bytes(width,'big')+b'ZZ')
(root/'GEOIP-LICENSE.txt').write_text('IP Geolocation by DB-IP: https://db-ip.com\nDB-IP Country Lite, October 2026. Licensed under CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\nConverted to a binary country-only range index by Nestic. Reduced-accuracy IP estimates; VPNs and relays can differ from actual location.\n')
print('Built offline country database. Source SHA256:',hashlib.sha256(raw).hexdigest())
