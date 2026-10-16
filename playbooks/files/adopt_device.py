#!/usr/bin/env python3
"""Build the platform Device for a device that already runs Teknoir (adopt-device.yml).

Input (stdin, JSON): {"name", "namespace", "board", "tunnel_port", "labels": {...},
                      "rsa_private", "rsa_public" (PEM text), "objects": <kubectl get -o json List>}
Output (stdout, JSON): {"device": <Device manifest>, "apps": [<"Kind/ns/name">, ...]}

The device's own key pair is kept (it is the k3s root CA and the identity TOE signs its MQTT
JWT with), so k3s and TOE need no change. spec.manifest.apps is rebuilt from the top-level
objects TOE applied from the previous platform (teknoir.org/managed-by=devstudio as annotation or
label, not
created by a Helm chart), so TOE does not prune the device's apps when it syncs the new,
otherwise empty, Device. Never prints a key.
"""
import base64
import json
import sys

RUNTIME_META = ("uid", "resourceVersion", "creationTimestamp", "managedFields", "generation",
                "selfLink", "ownerReferences", "deletionTimestamp", "deletionGracePeriodSeconds")
RUNTIME_ANNOTATIONS = ("kubectl.kubernetes.io/last-applied-configuration", "deployment.kubernetes.io/revision",
                       "objectset.rio.cattle.io/applied", "objectset.rio.cattle.io/id")
DEFAULT_KEYS = {  # Backstage DEVICE_DEFAULT spec.keys.data (base64)
    "ethernetipaddress": "MTkyLjE2OC4xLjE=", "ethernetmode": "ZHluYW1pYw==", "ethernetsubnet": "MjQ=",
    "publicsshkey": "IA==", "usermode": "ZGVmYXVsdA==", "username": "dGVrbm9pcg==",
    "wificountry": "VVM=", "wifiipaddress": "MTkyLjE2OC4yLjE=", "wifimode": "bm93aWZp",
    "wifissid": "dGVrbm9pcndpZmk=", "wifisubnet": "MjQ=",
}


def b64(s):
    return base64.b64encode(s.encode()).decode()


def is_top_level(o):
    md = o.get("metadata") or {}
    labels = md.get("labels") or {}
    ann = md.get("annotations") or {}
    if "devstudio" not in (labels.get("teknoir.org/managed-by"), ann.get("teknoir.org/managed-by")):
        return False
    if md.get("ownerReferences"):
        return False  # made by a controller (ReplicaSet, Helm job, ...)
    if "meta.helm.sh/release-name" in ann or labels.get("app.kubernetes.io/managed-by") == "Helm":
        return False  # rendered by a HelmChart that is itself in the manifest
    return True


def clean(o):
    o = json.loads(json.dumps(o))
    o.pop("status", None)
    md = o["metadata"]
    for k in RUNTIME_META:
        md.pop(k, None)
    ann = md.get("annotations") or {}
    for k in RUNTIME_ANNOTATIONS:
        ann.pop(k, None)
    if ann:
        md["annotations"] = ann
    else:
        md.pop("annotations", None)
    if o.get("kind") == "Service":
        spec = o.get("spec") or {}
        for k in ("clusterIP", "clusterIPs"):
            spec.pop(k, None)
    return o


def main():
    inp = json.load(sys.stdin)
    apps, names = {}, []
    for o in (inp.get("objects") or {}).get("items", []):
        if not is_top_level(o):
            continue
        o = clean(o)
        ns = o["metadata"].get("namespace") or "default"
        key = f'{o["kind"]}-{o["metadata"]["name"]}-{ns}'
        apps[key] = o
        names.append(f'{o["kind"]}/{ns}/{o["metadata"]["name"]}')
    data = dict(DEFAULT_KEYS)
    data.update({
        "board": b64(inp["board"]),
        "tunnel": b64(str(inp["tunnel_port"]) if inp.get("tunnel_port") else "NA"),
        "rsa_private": b64(inp["rsa_private"]),
        "rsa_public": b64(inp["rsa_public"]),
    })
    labels = {"teknoir": "alpha", "hardware": inp["board"]}
    labels.update(inp.get("labels") or {})
    device = {
        "apiVersion": "teknoir.org/v1", "kind": "Device",
        "metadata": {"name": inp["name"], "namespace": inp["namespace"], "labels": labels},
        "spec": {"keys": {"type": "Opaque", "metadata": {}, "data": data},
                 "manifest": {"apps": apps}, "plugins": []},
    }
    json.dump({"device": device, "apps": sorted(names)}, sys.stdout)


if __name__ == "__main__":
    main()
