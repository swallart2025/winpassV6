#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Vérification V3 contre PostgreSQL réel : moteur comportemental (score avec
décroissance + seuil de rechargement, batch mensuel, CIC) et campagnes temps
réel (éligibilité, cashback tout-ou-rien, clôture). Dates contrôlées.
"""
import os
import psycopg2, json
from decimal import Decimal, ROUND_HALF_UP, getcontext
from datetime import datetime, timedelta
getcontext().prec = 40
DSN = os.environ.get("WINPASS_DSN", "dbname=winpass_test user=winpass password=winpass host=localhost")
Q6 = Decimal("0.000001")
def r6(x): return Decimal(x).quantize(Q6, rounding=ROUND_HALF_UP)
def D(x): return Decimal(str(x))
def conn():
    c = psycopg2.connect(DSN); c.autocommit = False; return c

MC = {"CARREFOUR":"Alimentaire","BIO":"Alimentaire","FNAC":"Culture & Loisirs",
      "DECATHLON":"Culture & Loisirs","SEPHORA":"Beauté","LEROY":"Bricolage"}
# [name, max, validity_months, qualifying_min €]
CATS = [["Alimentaire",35,1,50],["Restaurants",10,1,30],["Culture & Loisirs",10,3,40],
        ["Mode",8,3,60],["Beauté",5,3,30],["Voyage",8,6,200],["Bricolage",6,6,50],
        ["Jardin/Animaux",5,6,40],["Équipement maison",13,12,150]]
SCALE = [[0,19,0],[20,39,25],[40,59,50],[60,79,75],[80,100,100]]
COMPO_RATE = D("0.15")

def seed():
    c=conn(); cur=c.cursor()
    cur.execute("""TRUNCATE memberships,reward_configs,member_sponsorships,wallets,earn_ledgers,wallet_lots,
      payments,payment_allocations,reversals,wallet_statements,pool_contributions,processed_events,
      merchant_categories,loyalty_category_configs,adherence_scale_configs,campaigns,campaign_rewards,
      cic_ledger,member_monthly_rewards,member_monthly_category_scores RESTART IDENTITY CASCADE""")
    cur.execute("""INSERT INTO reward_configs(version_label,personal_rate,sponsorship_rate,fonctionnement_rate,
      comportemental_rate,grands_leaders_rate,sponsorship_ratio,sponsorship_max_generation,distributions,effective_from)
      VALUES('V1-2026',0.45,0.20,0.125,0.15,0.075,0.70,5,'{}',now())""")
    for mid,name in {20:"Alice",120:"Bruno",300:"David",410:"Sophie",500:"Emma"}.items():
        cur.execute("INSERT INTO memberships(member_id,display_name,status,enrolled_at) VALUES(%s,%s,'active',now())",(mid,name))
        cur.execute("INSERT INTO wallets(member_id) VALUES(%s)",(mid,))
    for m,cat in MC.items():
        cur.execute("INSERT INTO merchant_categories(merchant_id,category) VALUES(%s,%s)",(m,cat))
    cur.execute("INSERT INTO loyalty_category_configs(version_label,categories,effective_from) VALUES('CAT-V1',%s,now())",
                (json.dumps([{"name":x[0],"max":x[1],"validity_months":x[2],"qualifying_min":x[3]} for x in CATS]),))
    cur.execute("INSERT INTO adherence_scale_configs(version_label,tranches,effective_from) VALUES('BAR-V1',%s,now())",
                (json.dumps(SCALE),))
    c.commit(); c.close()

def load_cats(cur):
    cur.execute("SELECT categories FROM loyalty_category_configs WHERE effective_to IS NULL")
    return {x["name"]:x for x in cur.fetchone()[0]}
def load_scale(cur):
    cur.execute("SELECT tranches FROM adherence_scale_configs WHERE effective_to IS NULL")
    return cur.fetchone()[0]

def record_purchase(member, amount, rate, merchant, when):
    """Enregistre la part utile au comportemental : earn personnel (assiette) +
    contribution comportementale (15 % du budget) datés à `when`."""
    c=conn(); cur=c.cursor()
    base=r6(D(amount)*D(rate)); compo=r6(base*COMPO_RATE)
    cur.execute("""INSERT INTO earn_ledgers(member_id,order_id,merchant_id,order_amount,commission_rate,earn_type,generation,amount,delivered_at)
                   VALUES(%s,%s,%s,%s,%s,'personal',0,%s,%s)""",(member,None,merchant,D(amount),D(rate),r6(base*D("0.45")),when))
    cur.execute("""INSERT INTO pool_contributions(pool_type,source_member_id,amount,created_at)
                   VALUES('comportemental',%s,%s,%s)""",(member,compo,when))
    c.commit(); c.close()

def category_contribution(cur, member, cat, as_of):
    """Décroissance + rechargement : renvoie (cumul_courant, dernier_rechargement, contribution)."""
    meta=load_cats(cur)[cat]; qmin=D(meta["qualifying_min"]); mx=D(meta["max"]); dur=int(meta["validity_months"])
    cur.execute("""SELECT e.order_amount, e.delivered_at FROM earn_ledgers e
                   JOIN merchant_categories mc ON mc.merchant_id=e.merchant_id
                   WHERE e.member_id=%s AND e.earn_type='personal' AND mc.category=%s AND e.delivered_at<=%s
                   ORDER BY e.delivered_at, e.id""",(member,cat,as_of))
    cumul=Decimal(0); last=None
    for amt,dt in cur.fetchall():
        cumul=r6(cumul+D(amt))
        if cumul>=qmin: last=dt; cumul=Decimal(0)   # rechargé -> reset
    if last is None: return cumul,None,Decimal(0)
    days=(as_of-last).days
    step=15 if dur==1 else 30
    steps=days//step
    elapsed_months=D(steps)*D(step)/D(30)
    contrib=r6(mx*max(Decimal(0), Decimal(1)-elapsed_months/D(dur)))
    return cumul,last,contrib

def adherence_score(cur, member, as_of):
    total=Decimal(0)
    for cat in load_cats(cur):
        total+=category_contribution(cur,member,cat,as_of)[2]
    return min(100, int(total))

def rate_for(cur, score):
    for a,z,t in load_scale(cur):
        if a<=score<=z: return t
    return 0

def cic_balance(cur):
    cur.execute("SELECT balance_after FROM cic_ledger ORDER BY id DESC LIMIT 1")
    r=cur.fetchone(); return D(r[0]) if r else Decimal(0)
def cic_move(cur, kind, amount, ref):
    bal=r6(cic_balance(cur)+D(amount))
    cur.execute("INSERT INTO cic_ledger(kind,amount,balance_after,reference) VALUES(%s,%s,%s,%s)",(kind,r6(amount),bal,json.dumps(ref)))
    return bal

# ============================ Batch mensuel ============================
def monthly_batch(period, as_of):
    c=conn(); cur=c.cursor(); out=[]
    cur.execute("SELECT member_id FROM memberships ORDER BY member_id")
    for (m,) in cur.fetchall():
        y,mo=period.split("-")
        cur.execute("""SELECT COALESCE(SUM(amount),0) FROM pool_contributions
                       WHERE pool_type='comportemental' AND source_member_id=%s
                       AND to_char(created_at,'YYYY-MM')=%s""",(m,period))
        potential=r6(D(cur.fetchone()[0]))
        if potential<=0: continue
        score=adherence_score(cur,m,as_of); rate=rate_for(cur,score)
        reward=r6(potential*D(rate)/D(100)); to_cic=r6(potential-reward)
        # crédite le wallet
        cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s FOR UPDATE",(m,))
        bal=r6(D(cur.fetchone()[0])+reward)
        cur.execute("UPDATE wallets SET available_balance=%s WHERE member_id=%s",(bal,m))
        cur.execute("""INSERT INTO member_monthly_rewards(member_id,period,potential,score,unlocked_rate,reward,cic_contribution)
                       VALUES(%s,%s,%s,%s,%s,%s,%s)""",(m,period,potential,score,rate,reward,to_cic))
        for cat in load_cats(cur):
            cum,last,contrib=category_contribution(cur,m,cat,as_of)
            if contrib>0 or last:
                cur.execute("""INSERT INTO member_monthly_category_scores(member_id,period,category,cumulative_amount,contribution,last_recharge_at)
                               VALUES(%s,%s,%s,%s,%s,%s)""",(m,period,cat,cum,contrib,last))
        cic_move(cur,'monthly_contribution',to_cic,{"member_id":m,"period":period})
        out.append({"member":m,"potential":potential,"score":score,"rate":rate,"reward":reward,"to_cic":to_cic})
    c.commit(); c.close(); return out

# ============================ Campagnes ============================
def campaign_create(category, seuil, rtype, value, budget, end_date):
    c=conn(); cur=c.cursor()
    bal=cic_balance(cur)
    if D(budget)>bal:
        c.rollback(); c.close(); return {"error":"cic_insuffisante","cic":str(bal)}
    cur.execute("""INSERT INTO campaigns(category,eligibility_score_max,reward_type,reward_value,budget_reserved,end_date,status)
                   VALUES(%s,%s,%s,%s,%s,%s,'active') RETURNING id""",(category,seuil,rtype,D(value),D(budget),end_date))
    cid=cur.fetchone()[0]
    cic_move(cur,'campaign_reserve',-D(budget),{"campaign_id":cid})
    c.commit(); c.close(); return {"campaign_id":cid}

def close_campaign(cur, cid, reason):
    cur.execute("SELECT budget_reserved,budget_spent FROM campaigns WHERE id=%s",(cid,))
    br,bs=cur.fetchone(); reliquat=r6(D(br)-D(bs))
    cur.execute("UPDATE campaigns SET status='closed',reliquat=%s,closed_reason=%s WHERE id=%s",(reliquat,reason,cid))
    if reliquat>0: cic_move(cur,'campaign_release',reliquat,{"campaign_id":cid,"reliquat":str(reliquat)})

def campaign_award(member, order_amount, merchant, when):
    """Temps réel : à l'achat, si le membre est éligible à une campagne active sur
    la catégorie, verse le cashback (tout-ou-rien) et décompte le budget."""
    c=conn(); cur=c.cursor()
    cat=MC.get(merchant)
    if not cat: c.close(); return None
    cur.execute("SELECT id,eligibility_score_max,reward_type,reward_value,budget_reserved,budget_spent,end_date FROM campaigns WHERE category=%s AND status='active'",(cat,))
    row=cur.fetchone()
    if not row: c.close(); return None
    cid,seuil,rtype,rval,br,bs,end=row
    # clôture si date dépassée
    if end and when.date()>end:
        close_campaign(cur,cid,'date'); c.commit(); c.close(); return None
    score=adherence_score(cur,member,when)
    if score>seuil: c.close(); return None    # non éligible
    bonus=r6(D(rval)) if rtype=='value' else r6(D(order_amount)*D(rval)/D(100))
    room=r6(D(br)-D(bs))
    if room<bonus:     # tout-ou-rien : budget insuffisant -> la campagne s'arrête
        close_campaign(cur,cid,'budget'); c.commit(); c.close(); return {"status":"stopped_budget"}
    cur.execute("UPDATE campaigns SET budget_spent=budget_spent+%s WHERE id=%s",(bonus,cid))
    cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s FOR UPDATE",(member,))
    bal=r6(D(cur.fetchone()[0])+bonus)
    cur.execute("UPDATE wallets SET available_balance=%s WHERE member_id=%s",(bal,member))
    cur.execute("INSERT INTO campaign_rewards(campaign_id,member_id,order_id,amount) VALUES(%s,%s,%s,%s)",(cid,member,None,bonus))
    if r6(D(bs)+bonus)>=D(br): close_campaign(cur,cid,'budget')
    c.commit(); c.close(); return {"status":"paid","bonus":bonus,"campaign_id":cid}

def wallet(member):
    c=conn(); cur=c.cursor(); cur.execute("SELECT available_balance FROM wallets WHERE member_id=%s",(member,)); v=D(cur.fetchone()[0]); c.close(); return v
