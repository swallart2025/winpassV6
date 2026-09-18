#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Banc de concurrence au niveau BASE (PostgreSQL réel) : prouve la garantie sur
laquelle repose le moteur Rails — la sérialisation des écritures d'un même
portefeuille par verrou de ligne (SELECT ... FOR UPDATE).

  * N threads créditent CONCURREMMENT le même portefeuille (le pire cas : toutes
    les écritures se disputent la même ligne). Avec le verrou, aucune mise à jour
    perdue -> solde final EXACT. On mesure aussi le débit réel (tx/s).
  * Idempotence sous concurrence : M threads tentent la MÊME clé d'événement ;
    l'unicité en base n'en laisse passer qu'une (les autres -> conflit propre).
"""
import os
import psycopg2, threading, time
from decimal import Decimal, ROUND_HALF_UP, getcontext
getcontext().prec = 40
DSN = os.environ.get("WINPASS_DSN", "dbname=winpass_test user=winpass password=winpass host=localhost")
def D(x): return Decimal(str(x))
def r6(x): return Decimal(x).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)

def setup():
    c = psycopg2.connect(DSN); c.autocommit = True; cur = c.cursor()
    cur.execute("TRUNCATE wallets, wallet_statements, processed_events RESTART IDENTITY CASCADE")
    cur.execute("INSERT INTO wallets(member_id, available_balance) VALUES (777, 0) ON CONFLICT DO NOTHING")
    c.close()

def credit_once(member, amount, barrier):
    """Une transaction 'earn' : verrou de ligne -> lecture -> écriture -> relevé."""
    c = psycopg2.connect(DSN); c.autocommit = False; cur = c.cursor()
    barrier.wait()  # tous les threads démarrent en même temps -> vraie contention
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s FOR UPDATE", (member,))
    bal = D(cur.fetchone()[0])
    after = r6(bal + D(amount))
    cur.execute("UPDATE wallets SET available_balance=%s WHERE member_id=%s", (after, member))
    cur.execute("""INSERT INTO wallet_statements(member_id,kind,label,amount,balance_after,created_at,updated_at)
      VALUES(%s,'personal_earn','earn concurrent',%s,%s,now(),now())""", (member, amount, after))
    c.commit(); c.close()

def test_no_lost_updates(N=60, amount="1.0"):
    setup()
    barrier = threading.Barrier(N)
    threads = [threading.Thread(target=credit_once, args=(777, amount, barrier)) for _ in range(N)]
    t0 = time.time()
    for t in threads: t.start()
    for t in threads: t.join()
    dt = time.time() - t0
    c = psycopg2.connect(DSN); cur = c.cursor()
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=777"); bal = D(cur.fetchone()[0])
    cur.execute("SELECT COUNT(*), COALESCE(SUM(amount),0) FROM wallet_statements WHERE member_id=777")
    n, s = cur.fetchone(); c.close()
    expected = r6(D(amount) * N)
    ok_bal = bal == expected
    ok_inv = bal == D(s)  # invariant Σ(relevé) == solde
    tps = N / dt if dt > 0 else 0
    print(f"  {N} crédits concurrents sur LE MÊME portefeuille (contention maximale)")
    print(f"  {'✓' if ok_bal else '✗'} aucune mise à jour perdue : solde={bal} == attendu={expected}")
    print(f"  {'✓' if ok_inv else '✗'} invariant Σ(relevé)={D(s)} == solde={bal}  ({n} lignes)")
    print(f"  débit mesuré : {tps:.0f} transactions/seconde  ({N} tx en {dt*1000:.0f} ms)")
    print(f"  → cible métier 10 tx/s : {'TENUE avec large marge' if tps >= 10 else 'NON TENUE'} (×{tps/10:.0f})")
    return ok_bal and ok_inv

def test_idempotency_race(M=25, key="ord-CONCURRENT-1"):
    c = psycopg2.connect(DSN); c.autocommit = True
    c.cursor().execute("TRUNCATE processed_events RESTART IDENTITY"); c.close()
    winners = []; lock = threading.Lock(); barrier = threading.Barrier(M)
    def attempt():
        cc = psycopg2.connect(DSN); cc.autocommit = False; cur = cc.cursor()
        barrier.wait()
        try:
            cur.execute("INSERT INTO processed_events(event_key,event_type,status,created_at,updated_at) VALUES(%s,'OrderDelivered','processing',now(),now())", (key,))
            cc.commit()
            with lock: winners.append(1)
        except psycopg2.errors.UniqueViolation:
            cc.rollback()   # conflit propre -> ce thread renvoie 'duplicate'
        finally:
            cc.close()
    ts = [threading.Thread(target=attempt) for _ in range(M)]
    for t in ts: t.start()
    for t in ts: t.join()
    c = psycopg2.connect(DSN); cur = c.cursor()
    cur.execute("SELECT COUNT(*) FROM processed_events WHERE event_key=%s", (key,)); rows = cur.fetchone()[0]; c.close()
    ok = (len(winners) == 1 and rows == 1)
    print(f"  {M} threads, MÊME clé d'idempotence")
    print(f"  {'✓' if ok else '✗'} un seul gagnant ({len(winners)}), une seule ligne en base ({rows}) — les {M-1} autres = doublon propre")
    return ok

if __name__ == "__main__":
    import sys
    print("\n=== 1) Sérialisation par verrou de ligne — pas de mise à jour perdue ===")
    a = test_no_lost_updates()
    print("\n=== 2) Idempotence sous concurrence — une seule écriture acceptée ===")
    b = test_idempotency_race()
    print()
    sys.exit(0 if (a and b) else 1)
