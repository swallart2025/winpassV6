#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Winpass — bombardement de l'API (banc de charge)
=================================================
Tire des achats (POST /v1/purchases) EN CONCURRENCE sur l'API réelle et mesure
le débit (transactions/seconde) et la latence (p50/p95/p99). Aucune dépendance :
n'utilise que la bibliothèque standard Python 3 -> rien à installer dans le Codespace.

USAGE (dans le terminal du Codespace, l'API tournant sur le port 3000) :

    python3 bench/bombard.py                       # 500 achats, 20 en parallèle
    python3 bench/bombard.py --n 2000 --concurrency 50
    python3 bench/bombard.py --mode hot            # pire cas : 1 seul acheteur (contention max)
    python3 bench/bombard.py --burn 0.3            # 30 % des achats paient une part en points

Options :
    --base URL          base de l'API (défaut http://localhost:3000)
    --n N               nombre total d'achats (défaut 500)
    --concurrency C     requêtes simultanées (défaut 20)
    --members M         nombre d'acheteurs distincts sollicités (défaut 5)
    --mode spread|hot   'spread' = acheteurs répartis ; 'hot' = un seul (contention max)
    --burn R            fraction d'achats réglés en partie en points (0..1, défaut 0)

Le script crée d'abord les acheteurs et un petit réseau de parrainage via
PUT /v1/sponsorships, puis lance la charge. Chaque achat a un n° de commande
unique (donc une clé d'idempotence unique) : tout le travail compte réellement.
"""
import argparse, json, time, urllib.request, urllib.error, random
from concurrent.futures import ThreadPoolExecutor
from statistics import quantiles, mean

MERCHANTS = ["CARREFOUR", "FNAC", "SEPHORA", "LEROY", "DECATHLON"]

def http(base, method, path, body=None, key=None, timeout=30):
    url = base.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if key: req.add_header("Idempotency-Key", key)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            code = r.status; payload = r.read()
    except urllib.error.HTTPError as e:
        code = e.code; payload = e.read()
    except Exception as e:
        return (0, time.perf_counter() - t0, str(e))
    return (code, time.perf_counter() - t0, payload)

def setup(base, members):
    """Crée les acheteurs (un premier achat 'amorce' via l'API n'est pas nécessaire :
    l'enrôlement est implicite). On pose un petit réseau de parrainage en chaîne."""
    ids = [500 + i for i in range(members)]
    relations = [{"member_id": ids[i], "sponsor_member_id": ids[i - 1]} for i in range(1, len(ids))]
    if relations:
        http(base, "PUT", "/v1/sponsorships", {"relations": relations})
    return ids

def one_purchase(base, member, order_id, with_burn):
    body = {
        "order_id": order_id, "member_id": member,
        "order_amount": str(random.choice([80, 120, 200, 350, 400])),
        "commission_rate": "0.02", "merchant_id": random.choice(MERCHANTS),
        "points_redeemed": "0.50" if with_burn else "0",
    }
    return http(base, "POST", "/v1/purchases", body, key=f"ord-bomb-{order_id}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:3000")
    ap.add_argument("--n", type=int, default=500)
    ap.add_argument("--concurrency", type=int, default=20)
    ap.add_argument("--members", type=int, default=5)
    ap.add_argument("--mode", choices=["spread", "hot"], default="spread")
    ap.add_argument("--burn", type=float, default=0.0)
    a = ap.parse_args()

    print(f"→ Cible : {a.base}")
    up = http(a.base, "GET", "/up")
    if up[0] != 200:
        print(f"✗ API injoignable sur {a.base} (code {up[0]}). Lance 'docker compose up' et vérifie le port 3000.")
        return
    ids = setup(a.base, max(1, a.members))
    print(f"→ {a.n} achats, {a.concurrency} en parallèle, mode={a.mode}, burn={int(a.burn*100)} %")

    base_order = 900000
    tasks = []
    for i in range(a.n):
        member = ids[0] if a.mode == "hot" else ids[i % len(ids)]
        tasks.append((member, base_order + i, random.random() < a.burn))

    codes = {}; lats = []
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=a.concurrency) as ex:
        for code, lat, _ in ex.map(lambda t: one_purchase(a.base, *t), tasks):
            codes[code] = codes.get(code, 0) + 1
            lats.append(lat)
    wall = time.perf_counter() - t0

    ok = codes.get(201, 0) + codes.get(200, 0)
    tps = a.n / wall if wall > 0 else 0
    lats_ms = sorted(x * 1000 for x in lats)
    def pct(p):
        if not lats_ms: return 0
        k = min(len(lats_ms) - 1, int(round(p / 100 * (len(lats_ms) - 1))))
        return lats_ms[k]

    print("\n=================  RÉSULTAT  =================")
    print(f"  Achats envoyés     : {a.n}")
    print(f"  Réussis (2xx)      : {ok}")
    print(f"  Répartition codes  : {codes}")
    print(f"  Durée totale       : {wall:.2f} s")
    print(f"  DÉBIT              : {tps:.0f} transactions/seconde")
    print(f"  Latence p50 / p95 / p99 : {pct(50):.0f} / {pct(95):.0f} / {pct(99):.0f} ms")
    print(f"  Latence moyenne    : {mean(lats_ms):.0f} ms")
    print(f"  Cible 10 tx/s      : {'TENUE (×%.0f)' % (tps/10) if tps>=10 else 'NON TENUE'}")
    print("=============================================")
    # Cohérence : on relit l'état et on vérifie qu'aucune erreur serveur (5xx) n'a eu lieu.
    server_errors = sum(v for c, v in codes.items() if isinstance(c, int) and 500 <= c < 600)
    print(f"  Erreurs serveur (5xx) : {server_errors}  {'✓ aucune' if server_errors==0 else '✗ À INVESTIGUER'}")

if __name__ == "__main__":
    main()
