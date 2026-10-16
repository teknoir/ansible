#!/usr/bin/env python3
"""Print the sha256 of the DER device certificate in a Teknoir bootstrap script (_RSA_PUBLIC).

The device certificate is the root of the device's k3s CA. rebootstrap-device.yml compares this
fingerprint with the one of /etc/teknoir/rsa_public.pem on the device, without printing either.
"""
import re
import subprocess
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    m = re.search(r'^_RSA_PUBLIC="(.*?)"$', f.read(), re.S | re.M)
if not m:
    sys.exit("no _RSA_PUBLIC in the bootstrap script")
der = subprocess.run(["openssl", "x509", "-outform", "DER"], input=m.group(1).encode(),
                     capture_output=True, check=True).stdout
print(subprocess.run(["sha256sum"], input=der, capture_output=True, check=True).stdout.decode().split()[0])
