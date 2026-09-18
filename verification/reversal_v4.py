#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Vérification V4 — correctif du bug #1 (l'annulation doit invalider les lots)
contre un PostgreSQL RÉEL. On reproduit à l'identique la nouvelle logique du
ReversalEngine Ruby :

  recoverable = (lot.status == 'active') ? min(earn.amount, lot.remaining) : 0
  solde       -= recoverable                # jamais négatif : borné au reliquat du lot
  si lot actif -> lot.remaining = 0, status = 'reversed'   # plus consommable en FEFO

Invariants contrôlés après chaque scénario :
  (I1) solde du portefeuille == Σ(remaining) des lots ACTIFS      (cohérence lots/solde)
  (I2) solde >= 0                                                  (jamais négatif)
  (I3) un lot annulé (reversed) n'est JAMAIS sélectionné en FEFO   (plus de lot fantôme)
"""
import os
import psycopg2
from decimal import Decimal, ROUND_HALF_UP, getcontext
from datetime import datetime, timedelta
getcontext().prec = 40
DSN = os.environ.get("WINPASS_DSN", "dbname=winpass_test user=winpass password=winpass host=localhost")
Q6 = Decimal("0.000001")
def r6(x): return Decimal(x).quantize(Q6, rounding=ROUND_HALF_UP)
def D(x):  return Decimal(str(x))
BASE = datetime(2026, 1, 1, 12, 0, 0)

def conn():
    c = psycopg2.connect(DSN); c.autocommit = False; return c

def reset(cur):
    cur.execute("""TRUNCATE memberships,wallets,earn_ledgers,wallet_lots,payments,
      payment_allocations,reversals,wallet_statements,processed_events RESTART IDENTITY CASCADE""")
    cur.execute("INSERT INTO memberships(member_id,display_name,status,enrolled_at) VALUES(500,'Emma','active',now())")
    cur.execute("INSERT INTO wallets(member_id) VALUES(500)")

# --- primitives comptables (miroir de LoyaltyLedger#apply_movement!) -----------
def move(cur, member, amount, kind, label, order_id=None):
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s FOR UPDATE",(member,))
    before = D(cur.fetchone()[0]); after = r6(before+D(amount))
    cur.execute("UPDATE wallets SET available_balance=%s WHERE member_id=%s",(after,member))
    cur.execute("""INSERT INTO wallet_statements(member_id,kind,label,order_id,amount,balance_after,created_at,updated_at)
      VALUES(%s,%s,%s,%s,%s,%s,now(),now())""",(member,kind,label,order_id,r6(amount),after))
    return after

# --- achat -> earn (personnel) : earn_ledger + lot actif + relevé + solde ------
def earn(cur, member, order_id, merchant, amount, when, exp):
    cur.execute("""INSERT INTO earn_ledgers(member_id,order_id,merchant_id,order_amount,commission_rate,
      earn_type,generation,amount,applied_rate,delivered_at,expires_at,created_at,updated_at)
      VALUES(%s,%s,%s,%s,0.02,'personal',0,%s,0.45,%s,%s,now(),now()) RETURNING id""",
      (member,order_id,merchant,amount,amount,when,exp))
    eid = cur.fetchone()[0]
    cur.execute("""INSERT INTO wallet_lots(earn_id,member_id,unit,initial_amount,remaining,status,earned_at,expires_at,created_at,updated_at)
      VALUES(%s,%s,'EUR',%s,%s,'active',%s,%s,now(),now())""",(eid,member,amount,amount,when,exp))
    move(cur, member, amount, 'personal_earn', 'Earn personnel', order_id)
    return eid

# --- burn FEFO : consomme les lots actifs (plus tôt expirés d'abord) -----------
def burn(cur, member, order_id, merchant, amount):
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s FOR UPDATE",(member,))
    bal = D(cur.fetchone()[0])
    assert bal >= D(amount), f"solde insuffisant pour burn {amount} (dispo {bal})"
    cur.execute("""INSERT INTO payments(member_id,order_id,merchant_id,amount,status,created_at,updated_at)
      VALUES(%s,%s,%s,%s,'settled',now(),now()) RETURNING id""",(member,order_id,merchant,amount))
    pid = cur.fetchone()[0]; remaining = D(amount)
    cur.execute("""SELECT id,remaining FROM wallet_lots WHERE member_id=%s AND status='active' AND remaining>0
      ORDER BY expires_at,earned_at,id FOR UPDATE""",(member,))
    for lot_id, rem in cur.fetchall():
        if remaining <= 0: break
        take = min(remaining, D(rem)); newrem = r6(D(rem)-take)
        cur.execute("UPDATE wallet_lots SET remaining=%s,status=%s WHERE id=%s",
                    (newrem,'consumed' if newrem<=0 else 'active',lot_id))
        cur.execute("INSERT INTO payment_allocations(payment_id,wallet_lot_id,amount,created_at,updated_at) VALUES(%s,%s,%s,now(),now())",
                    (pid,lot_id,take))
        remaining = r6(remaining-take)
    move(cur, member, -D(amount), 'burn', 'Paiement en points', order_id)

# --- ANNULATION V4 (le correctif) ---------------------------------------------
def reverse(cur, order_id):
    cur.execute("SELECT id,member_id,earn_type,generation,amount FROM earn_ledgers WHERE order_id=%s ORDER BY id",(order_id,))
    clawback = D(0)
    for eid, member, etype, gen, amt in cur.fetchall():
        cur.execute("SELECT id,status,remaining FROM wallet_lots WHERE earn_id=%s FOR UPDATE",(eid,))
        row = cur.fetchone()
        recoverable = D(0)
        if row and row[1] == 'active':
            recoverable = min(D(amt), D(row[2]))
        lbl = 'Annulation earn personnel' if etype=='personal' else f'Annulation gain parrainage · G{gen}'
        if recoverable < D(amt):
            lbl += f" — repris {recoverable:.2f} € / {D(amt):.2f} € (solde déjà dépensé)"
        move(cur, member, -recoverable, 'reversal_earn', lbl, order_id)
        if row and row[1] == 'active':
            cur.execute("UPDATE wallet_lots SET remaining=0,status='reversed' WHERE id=%s",(row[0],))
        clawback += recoverable
    # restitution du burn (si l'ordre contenait un paiement) — inchangé V3
    cur.execute("SELECT id,member_id,amount FROM payments WHERE order_id=%s AND status='settled'",(order_id,))
    for pid, member, pamt in cur.fetchall():
        cur.execute("SELECT wallet_lot_id,amount FROM payment_allocations WHERE payment_id=%s",(pid,))
        for lot_id, aamt in cur.fetchall():
            cur.execute("SELECT remaining FROM wallet_lots WHERE id=%s FOR UPDATE",(lot_id,))
            newrem = r6(D(cur.fetchone()[0])+D(aamt))
            cur.execute("UPDATE wallet_lots SET remaining=%s,status='active' WHERE id=%s",(newrem,lot_id))
        cur.execute("UPDATE payments SET status='reversed' WHERE id=%s",(pid,))
        move(cur, member, D(pamt), 'reversal_burn', 'Annulation paiement — points restitués', order_id)
    cur.execute("""INSERT INTO reversals(order_id,reversal_type,earn_clawback_total,created_at,updated_at)
      VALUES(%s,'earn',%s,now(),now())""",(order_id,clawback))
    return clawback

# --- invariants ----------------------------------------------------------------
def check_invariants(cur, member, tag, results):
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s",(member,))
    bal = D(cur.fetchone()[0])
    cur.execute("SELECT COALESCE(SUM(remaining),0) FROM wallet_lots WHERE member_id=%s AND status='active'",(member,))
    active_sum = D(cur.fetchone()[0])
    results.append((f"[{tag}] (I1) solde == Σ lots actifs  ({bal} == {active_sum})", bal==active_sum))
    results.append((f"[{tag}] (I2) solde >= 0  ({bal})", bal>=0))

def check_fefo_excludes_reversed(cur, member, tag, results):
    cur.execute("""SELECT COUNT(*) FROM wallet_lots
      WHERE member_id=%s AND status='reversed' AND remaining>0""",(member,))
    ghost = cur.fetchone()[0]
    results.append((f"[{tag}] (I3) aucun lot 'reversed' consommable (remaining>0) : {ghost}", ghost==0))

def run():
    c = conn(); cur = c.cursor(); results = []

    # === Scénario A : annulation simple, lot intact -> reversed, solde -montant ===
    reset(cur)
    earn(cur, 500, 1001, 'CARREFOUR', D(10), BASE, BASE+timedelta(days=730))
    reverse(cur, 1001)
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=500"); balA=D(cur.fetchone()[0])
    cur.execute("SELECT status,remaining FROM wallet_lots WHERE earn_id=1"); stA=cur.fetchone()
    results.append(("[A] solde revient à 0 après annulation totale", balA==D(0)))
    results.append(("[A] lot d'origine -> status 'reversed', remaining 0", stA[0]=='reversed' and D(stA[1])==0))
    check_invariants(cur, 500, "A", results)
    check_fefo_excludes_reversed(cur, 500, "A", results)

    # === Scénario B : lot partiellement consommé -> clawback CLAMPÉ au reliquat ===
    reset(cur)
    # Order 1 : earn 10 (expire tôt -> sera le 1er servi en FEFO)
    earn(cur, 500, 2001, 'CARREFOUR', D(10), BASE, BASE+timedelta(days=365))
    # Order 2 : earn 2 (expire plus tard) + burn 4 -> FEFO consomme 4 sur le lot #1
    earn(cur, 500, 2002, 'FNAC', D(2), BASE+timedelta(days=1), BASE+timedelta(days=730))
    burn(cur, 500, 2002, 'FNAC', D(4))
    cur.execute("SELECT remaining,status FROM wallet_lots WHERE earn_id=1"); l1=cur.fetchone()
    # lot #1 : 10 - 4 = 6 restants, encore actif
    results.append(("[B] pré-annulation : lot #1 remaining 6, actif", D(l1[0])==6 and l1[1]=='active'))
    claw = reverse(cur, 2001)  # annule l'earn de 10 ; seulement 6 récupérables
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=500"); balB=D(cur.fetchone()[0])
    cur.execute("SELECT status,remaining FROM wallet_lots WHERE earn_id=1"); l1b=cur.fetchone()
    # solde avant annulation = 10+2-4 = 8 ; on reprend 6 -> 2 (le lot #2)
    results.append(("[B] clawback clampé à 6 (et non 10)", claw==D(6)))
    results.append(("[B] solde final = 2 (lot #2), jamais négatif", balB==D(2)))
    results.append(("[B] lot #1 -> reversed, remaining 0", l1b[0]=='reversed' and D(l1b[1])==0))
    check_invariants(cur, 500, "B", results)
    check_fefo_excludes_reversed(cur, 500, "B", results)
    # I3 renforcé : un nouveau burn ne doit PAS toucher le lot reversed
    burn(cur, 500, 2003, 'FNAC', D(2))   # consomme le lot #2 (seul actif)
    cur.execute("SELECT status,remaining FROM wallet_lots WHERE earn_id=1"); l1c=cur.fetchone()
    results.append(("[B] après nouveau burn, lot #1 reste reversed/0 (non consommé)", l1c[0]=='reversed' and D(l1c[1])==0))

    # === Scénario C : lot totalement consommé -> clawback 0, statut inchangé =====
    reset(cur)
    earn(cur, 500, 3001, 'CARREFOUR', D(5), BASE, BASE+timedelta(days=100))   # expire tôt
    earn(cur, 500, 3002, 'FNAC', D(1), BASE+timedelta(days=1), BASE+timedelta(days=730))
    burn(cur, 500, 3002, 'FNAC', D(5))   # consomme entièrement le lot #1
    cur.execute("SELECT status,remaining FROM wallet_lots WHERE earn_id=1"); c1=cur.fetchone()
    results.append(("[C] pré-annulation : lot #1 entièrement consommé", c1[0]=='consumed' and D(c1[1])==0))
    claw = reverse(cur, 3001)
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=500"); balC=D(cur.fetchone()[0])
    cur.execute("SELECT status,remaining FROM wallet_lots WHERE earn_id=1"); c1b=cur.fetchone()
    results.append(("[C] clawback = 0 (rien à reprendre, déjà dépensé)", claw==D(0)))
    results.append(("[C] lot #1 reste 'consumed' (pas relabellisé reversed)", c1b[0]=='consumed'))
    results.append(("[C] solde = 1 (lot #2), jamais négatif", balC==D(1)))
    check_invariants(cur, 500, "C", results)

    c.rollback(); c.close()

    # --- rapport ---
    ok = sum(1 for _,p in results if p)
    for msg, passed in results:
        print(("  ✓ " if passed else "  ✗ ")+msg)
    print(f"\n{ok}/{len(results)} contrôles VERTS")
    return ok==len(results)

if __name__ == "__main__":
    import sys
    sys.exit(0 if run() else 1)
