#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Vérification V4 — PURGE / ROLLBACK du batch mensuel comportemental, sur un
PostgreSQL réel. Reproduit à l'identique la logique de BehavioralRollback :

  * récompense INTACTE (lot actif & non entamé, ou récompense nulle) -> rollback
    complet (mouvement compensatoire, lot 'reversed', CIC annulée, photo purgée) ;
  * récompense (partiellement) UTILISÉE -> CONSERVÉE (acquise), le rejeu la saute.

Puis on REJOUE le batch et on vérifie que seuls les membres réinitialisés sont
retraités (pas de double versement), et que les invariants tiennent.
"""
import os
import psycopg2
from decimal import Decimal, ROUND_HALF_UP, getcontext
from datetime import datetime, timedelta
getcontext().prec = 40
DSN = os.environ.get("WINPASS_DSN", "dbname=winpass_test user=winpass password=winpass host=localhost")
def D(x): return Decimal(str(x))
def r6(x): return Decimal(x).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
PERIOD = "2026-07"
AT = datetime(2026, 7, 31, 12, 0, 0)

def conn():
    c = psycopg2.connect(DSN); c.autocommit = False; return c

def reset(cur):
    cur.execute("""TRUNCATE memberships,wallets,earn_ledgers,wallet_lots,payments,payment_allocations,
      wallet_statements,processed_events,member_monthly_rewards,member_monthly_category_scores,cic_ledger
      RESTART IDENTITY CASCADE""")
    for mid, name in {1: "A", 2: "B", 3: "C", 4: "D"}.items():
        cur.execute("INSERT INTO memberships(member_id,display_name,status,enrolled_at) VALUES(%s,%s,'active',now())", (mid, name))
        cur.execute("INSERT INTO wallets(member_id) VALUES(%s)", (mid,))

def move(cur, member, amount, kind, label, merchant=None):
    cur.execute("SELECT available_balance,personal_counter FROM wallets WHERE member_id=%s FOR UPDATE", (member,))
    bal, pc = cur.fetchone(); after = r6(D(bal) + D(amount))
    cur.execute("UPDATE wallets SET available_balance=%s, personal_counter=%s WHERE member_id=%s",
                (after, r6(D(pc) + D(amount)), member))
    cur.execute("""INSERT INTO wallet_statements(member_id,kind,label,merchant_id,amount,balance_after,created_at,updated_at)
      VALUES(%s,%s,%s,%s,%s,%s,now(),now())""", (member, kind, label, merchant, r6(amount), after))
    return after

def cic_move(cur, kind, amount):
    cur.execute("SELECT COALESCE((SELECT balance_after FROM cic_ledger ORDER BY id DESC LIMIT 1),0)")
    after = r6(D(cur.fetchone()[0]) + D(amount))
    cur.execute("INSERT INTO cic_ledger(kind,amount,balance_after,created_at,updated_at) VALUES(%s,%s,%s,now(),now())",
                (kind, r6(amount), after))
    return after

def cic_balance(cur):
    cur.execute("SELECT COALESCE((SELECT balance_after FROM cic_ledger ORDER BY id DESC LIMIT 1),0)")
    return D(cur.fetchone()[0])

# --- credit_reward! + photo mensuelle + contribution CIC (comme le batch) -------
def credit_reward(cur, member, reward):
    origin = f"Comportemental {PERIOD}"
    cur.execute("""INSERT INTO earn_ledgers(member_id,earn_type,generation,amount,merchant_id,delivered_at,expires_at,created_at,updated_at)
      VALUES(%s,'comportemental',0,%s,%s,%s,%s,now(),now()) RETURNING id""",
      (member, reward, origin, AT, AT + timedelta(days=730)))
    eid = cur.fetchone()[0]
    cur.execute("""INSERT INTO wallet_lots(earn_id,member_id,unit,initial_amount,remaining,status,earned_at,expires_at,created_at,updated_at)
      VALUES(%s,%s,'EUR',%s,%s,'active',%s,%s,now(),now())""", (eid, member, reward, reward, AT, AT + timedelta(days=730)))
    move(cur, member, reward, 'personal_earn', f"Récompense comportementale {PERIOD}", origin)

def run_batch(cur, plan):
    """plan: {member: (potential, reward, cic)}. Saute les membres ayant déjà une photo."""
    processed = []
    for member, (pot, reward, cic) in plan.items():
        cur.execute("SELECT 1 FROM member_monthly_rewards WHERE member_id=%s AND period=%s", (member, PERIOD))
        if cur.fetchone():
            continue  # déjà traité -> on saute (garde l'acquis)
        if reward > 0:
            credit_reward(cur, member, D(reward))
        cur.execute("""INSERT INTO member_monthly_rewards(member_id,period,potential,score,unlocked_rate,reward,cic_contribution,created_at,updated_at)
          VALUES(%s,%s,%s,50,50,%s,%s,now(),now())""", (member, PERIOD, D(pot), D(reward), D(cic)))
        cur.execute("""INSERT INTO member_monthly_category_scores(member_id,period,category,cumulative_amount,contribution,created_at,updated_at)
          VALUES(%s,%s,'Alimentaire',0,0,now(),now())""", (member, PERIOD))
        if D(cic) > 0:
            cic_move(cur, 'monthly_contribution', D(cic))
        processed.append(member)
    return processed

def consume(cur, member, amount):
    """Simule l'usage d'unités : réduit le lot comportemental du membre + burn."""
    cur.execute("""SELECT id,remaining FROM wallet_lots WHERE member_id=%s AND status='active' AND remaining>0
      ORDER BY expires_at,earned_at,id FOR UPDATE""", (member,))
    remaining = D(amount)
    for lot_id, rem in cur.fetchall():
        if remaining <= 0: break
        take = min(remaining, D(rem)); newrem = r6(D(rem) - take)
        cur.execute("UPDATE wallet_lots SET remaining=%s,status=%s WHERE id=%s",
                    (newrem, 'consumed' if newrem <= 0 else 'active', lot_id))
        remaining = r6(remaining - take)
    move(cur, member, -D(amount), 'burn', 'Paiement en points')

# --- PURGE / ROLLBACK (le correctif) ------------------------------------------
def reward_lot(cur, member):
    cur.execute("""SELECT id,status,remaining,initial_amount FROM wallet_lots
      WHERE earn_id=(SELECT id FROM earn_ledgers WHERE member_id=%s AND earn_type='comportemental'
                     AND merchant_id=%s ORDER BY id DESC LIMIT 1)""", (member, f"Comportemental {PERIOD}"))
    return cur.fetchone()

def purge(cur):
    cur.execute("SELECT member_id,reward,cic_contribution FROM member_monthly_rewards WHERE period=%s ORDER BY member_id", (PERIOD,))
    rows = cur.fetchall(); rolled = []; kept = []
    for member, reward, cic in rows:
        lot = reward_lot(cur, member)
        rollbackable = (D(reward) <= 0) or (lot and lot[1] == 'active' and D(lot[2]) == D(lot[3]))
        if not rollbackable:
            kept.append(member); continue
        if lot and D(reward) > 0:
            move(cur, member, -D(lot[2]), 'reversal_earn', f"Purge batch comportemental {PERIOD}", f"Comportemental {PERIOD}")
            cur.execute("UPDATE wallet_lots SET remaining=0,status='reversed' WHERE id=%s", (lot[0],))
        if D(cic) > 0:
            cic_move(cur, 'monthly_contribution', -D(cic))
        rolled.append(member)
    cur.execute("DELETE FROM member_monthly_rewards WHERE period=%s AND member_id = ANY(%s)", (PERIOD, rolled))
    cur.execute("DELETE FROM member_monthly_category_scores WHERE period=%s AND member_id = ANY(%s)", (PERIOD, rolled))
    return rolled, kept

def bal(cur, member):
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s", (member,)); return D(cur.fetchone()[0])
def stmt_sum(cur, member):
    cur.execute("SELECT COALESCE(SUM(amount),0) FROM wallet_statements WHERE member_id=%s", (member,)); return D(cur.fetchone()[0])
def has_reward(cur, member):
    cur.execute("SELECT COUNT(*) FROM member_monthly_rewards WHERE member_id=%s AND period=%s", (member, PERIOD)); return cur.fetchone()[0]

def run():
    c = conn(); cur = c.cursor(); res = []
    reset(cur)
    PLAN = {1: (10, 5, 5), 2: (10, 5, 5), 3: (10, 5, 5), 4: (4, 0, 4)}  # A intact, B partiel, C total, D nul
    run_batch(cur, PLAN)
    consume(cur, 2, D(2))   # B utilise 2 sur 5 (partiel)
    consume(cur, 3, D(5))   # C utilise 5 sur 5 (total)
    cic_after_batch = cic_balance(cur)
    res.append(("batch : CIC = 19 (5+5+5+4)", cic_after_batch == D(19)))
    res.append(("batch : soldes A=5 B=3 C=0 D=0",
                bal(cur,1)==D(5) and bal(cur,2)==D(3) and bal(cur,3)==D(0) and bal(cur,4)==D(0)))

    rolled, kept = purge(cur)
    res.append((f"purge : réinitialisés = A,D  (obtenu {sorted(rolled)})", sorted(rolled)==[1,4]))
    res.append((f"purge : conservés = B,C  (obtenu {sorted(kept)})", sorted(kept)==[2,3]))
    res.append(("purge : A remboursé -> solde 0, lot 'reversed'", bal(cur,1)==D(0) and reward_lot(cur,1)[1]=='reversed'))
    res.append(("purge : B intact -> solde 3, lot actif remaining 3", bal(cur,2)==D(3) and reward_lot(cur,2)[1]=='active' and D(reward_lot(cur,2)[2])==D(3)))
    res.append(("purge : C intact -> lot 'consumed'", reward_lot(cur,3)[1]=='consumed'))
    res.append(("purge : photos A,D supprimées ; B,C conservées",
                has_reward(cur,1)==0 and has_reward(cur,4)==0 and has_reward(cur,2)==1 and has_reward(cur,3)==1))
    res.append(("purge : CIC = 10 (annule 5+4, garde 5+5)", cic_balance(cur)==D(10)))
    for m in (1,2,3,4):
        res.append((f"purge : invariant Σ(relevé)==solde membre {m}", stmt_sum(cur,m)==bal(cur,m)))

    # REJEU : seuls A et D (photos supprimées) sont retraités ; B,C sautés.
    reproc = run_batch(cur, PLAN)
    res.append((f"rejeu : seuls A,D retraités (obtenu {sorted(reproc)})", sorted(reproc)==[1,4]))
    res.append(("rejeu : A re-crédité -> solde 5, nouveau lot actif", bal(cur,1)==D(5) and reward_lot(cur,1)[1]=='active'))
    res.append(("rejeu : B,C inchangés (pas de double versement)", bal(cur,2)==D(3) and bal(cur,3)==D(0)))
    res.append(("rejeu : CIC revient à 19", cic_balance(cur)==D(19)))
    cur.execute("SELECT COUNT(*) FROM member_monthly_rewards WHERE period=%s", (PERIOD,))
    res.append(("rejeu : une seule photo par membre (4 au total)", cur.fetchone()[0]==4))

    c.rollback(); c.close()
    ok = sum(1 for _, p in res if p)
    for msg, p in res: print(("  ✓ " if p else "  ✗ ") + msg)
    print(f"\n{ok}/{len(res)} contrôles VERTS")
    return ok == len(res)

if __name__ == "__main__":
    import sys
    sys.exit(0 if run() else 1)
