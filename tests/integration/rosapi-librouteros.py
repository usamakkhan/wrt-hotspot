#!/usr/bin/env python3
"""Check the RouterOS API subset with librouteros, a client library used by
many MikroTik tools. Run from a host in the router's api_allow list:

    pip install librouteros
    python3 rosapi-librouteros.py <router> <user> <password>
"""
import sys

from librouteros import connect
from librouteros.login import plain, token
from librouteros.query import Key

host, user, password = sys.argv[1:4]
ok = fail = 0


def check(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
        print(f"  ok    {name} {detail}")
    else:
        fail += 1
        print(f"  FAIL  {name} {detail}")


print("== librouteros against the RouterOS API subset")
for method, label in ((plain, "plain"), (token, "token (MD5 challenge)")):
    try:
        api = connect(host=host, username=user, password=password, login_method=method, timeout=5)
        ident = list(api.path("system", "identity"))[0]["name"]
        check(f"{label} login + /system/identity", bool(ident), f"({ident})")
        api.close()
    except Exception as e:
        check(f"{label} login", False, repr(e))

api = connect(host=host, username=user, password=password, timeout=5)

res = list(api.path("system", "resource"))[0]
check("/system/resource", "version" in res and int(res["total-memory"]) > 0,
      f"(version {res.get('version')}, cpu-load {res.get('cpu-load')}%)")

servers = list(api.path("ip", "hotspot"))
check("/ip/hotspot servers", len(servers) >= 1, f"({[s['name'] for s in servers]})")

users = api.path("ip", "hotspot", "user")
users.add(name="libros", password="pw2", profile="default", comment="librouteros")
found = [u for u in users if u["name"] == "libros"]
check("user add + list", len(found) == 1 and found[0]["comment"] == "librouteros")

name = Key("name")
q = list(users.select(name, Key("profile")).where(name == "libros"))
check("select/where query", q == [{"name": "libros", "profile": "default"}], str(q))

users.update(**{".id": found[0][".id"], "disabled": True})
check("update (set)", [u for u in users if u["name"] == "libros"][0]["disabled"] is True)

active = list(api.path("ip", "hotspot", "active"))
check("/ip/hotspot/active print", isinstance(active, list), f"({len(active)} online)")

queues = list(api.path("queue", "simple"))
check("/queue/simple print", isinstance(queues, list), f"({len(queues)} queues)")

users.remove(found[0][".id"])
check("user remove", not [u for u in users if u["name"] == "libros"])

try:
    list(api.path("ip", "firewall", "filter"))
    check("unsupported menu raises a trap", False)
except Exception as e:
    check("unsupported menu raises a trap", "no such command" in str(e), f"({e})")

api.close()
print(f"\nRESULT: {ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
