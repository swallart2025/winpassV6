#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import engine_v3 as E
from decimal import Decimal
from datetime import datetime
D=E.D
PASS=0; FAIL=0
def ok(label,cond,got=None,exp=None):
    global PASS,FAIL
    if cond: PASS+=1; print(f"  \033[32m✓\033[0m {label}")
    else: FAIL+=1; print(f"  \033[31m✗ {label}\033[0m (obtenu={got} attendu={exp})")
def eq(a,b): return abs(D(a)-D(b))<D("0.0000005")

print("="*66); print(" WINPASS V3 — comportemental & campagnes contre PostgreSQL réel"); print("="*66)

# ---- S1 : batch mensuel, score sans décroissance (achat le jour du batch) ----
print("\nS1 · Batch mensuel — Emma, 2 achats (Alimentaire+Culture), score 45")
E.seed()
d1=datetime(2026,7,15,10,0,0)
E.record_purchase(500,400,"0.02","CARREFOUR",d1)   # Alimentaire : 400≥50 -> rechargé, max 35
E.record_purchase(500,400,"0.02","FNAC",d1)        # Culture : 400≥40 -> rechargé, max 10
out=E.monthly_batch("2026-07", d1)
r=[x for x in out if x["member"]==500][0]
ok("potentiel = 2×(8×0.15)=2.40", eq(r["potential"],"2.40"), r["potential"])
ok("score = 35+10 = 45", r["score"]==45, r["score"])
ok("taux = 50 %", r["rate"]==50, r["rate"])
ok("récompense = 2.40×50% = 1.20", eq(r["reward"],"1.20"), r["reward"])
ok("vers CIC = 2.40-1.20 = 1.20", eq(r["to_cic"],"1.20"), r["to_cic"])
ok("solde Emma crédité de 1.20", eq(E.wallet(500),"1.20"))
ok("CIC = 1.20", eq(E.cic_balance(E.conn().cursor()),"1.20"))

# ---- S2 : seuil de rechargement — achat < montant qualificatif -> catégorie non rechargée ----
print("\nS2 · Seuil de rechargement — achat 40€ en Beauté (min 30) vs 20€ (min 30)")
E.seed()
E.record_purchase(500,40,"0.02","SEPHORA",datetime(2026,7,10))  # Beauté 40≥30 -> rechargé
c=E.conn(); cur=c.cursor()
_,last,contrib=E.category_contribution(cur,500,"Beauté",datetime(2026,7,10))
ok("Beauté rechargée (contrib = max 5)", eq(contrib,"5"), contrib)
c.close()
E.seed()
E.record_purchase(500,20,"0.02","SEPHORA",datetime(2026,7,10))  # Beauté 20<30 -> PAS rechargé
c=E.conn(); cur=c.cursor()
cum,last,contrib=E.category_contribution(cur,500,"Beauté",datetime(2026,7,10))
ok("Beauté non rechargée (contrib 0, cumul 20 en attente)", eq(contrib,"0") and eq(cum,"20"), (contrib,cum))
c.close()

# ---- S3 : décroissance dans le temps ----
print("\nS3 · Décroissance — Alimentaire (validité 1 mois, pas bi-hebdo)")
E.seed()
buy=datetime(2026,6,1)
E.record_purchase(500,400,"0.02","CARREFOUR",buy)  # rechargé le 1er juin, max 35
c=E.conn(); cur=c.cursor()
def contrib_at(days):
    from datetime import timedelta
    return E.category_contribution(cur,500,"Alimentaire",buy+timedelta(days=days))[2]
ok("à J+0 : 35 (plein)", eq(contrib_at(0),"35"), contrib_at(0))
ok("à J+15 : 17.5 (-50% bi-hebdo)", eq(contrib_at(15),"17.5"), contrib_at(15))
ok("à J+30 : 0 (validité 1 mois écoulée)", eq(contrib_at(30),"0"), contrib_at(30))
c.close()
# catégorie mensuelle 3 mois : Culture, décroissance mensuelle
E.seed(); E.record_purchase(500,400,"0.02","FNAC",buy)
c=E.conn(); cur=c.cursor()
def cult(days):
    from datetime import timedelta
    return E.category_contribution(cur,500,"Culture & Loisirs",buy+timedelta(days=days))[2]
ok("Culture J+0 : 10", eq(cult(0),"10"), cult(0))
ok("Culture J+30 : 6.666667 (1-1/3)", eq(cult(30),"6.666667"), cult(30))
ok("Culture J+90 : 0", eq(cult(90),"0"), cult(90))
c.close()

# ---- S4 : campagne temps réel — éligibilité, cashback, tout-ou-rien, clôture ----
print("\nS4 · Campagne temps réel")
E.seed()
# monter la CIC : un batch après un achat Emma
E.record_purchase(500,400,"0.02","CARREFOUR",datetime(2026,7,5))
E.monthly_batch("2026-07", datetime(2026,7,5))  # Emma potentiel 1.20, score 35 -> 25%? 35->[20,39]=25% ; reward .30 ; CIC .90
cic0=E.cic_balance(E.conn().cursor())
ok("CIC alimentée (>0)", cic0>0, cic0)
# campagne Beauté (Emma score Beauté=0 ≤ 20) bonus 0.50 €, budget = min(CIC,0.50)
budget=min(cic0, D("0.50"))
res=E.campaign_create("Beauté",20,"value","0.50",str(budget),None)
ok("campagne créée", "campaign_id" in res, res)
# Emma achète chez SEPHORA (Beauté) -> éligible -> cashback 0.50
before=E.wallet(500)
aw=E.campaign_award(500,100,"SEPHORA",datetime(2026,7,20))
ok("cashback versé (paid)", aw and aw.get("status")=="paid", aw)
ok("cashback = 0.50", aw and eq(aw["bonus"],"0.50"), aw)
ok("solde Emma +0.50", eq(E.wallet(500), before+D("0.50")))
# budget 0.50 épuisé -> campagne close
c=E.conn(); cur=c.cursor(); cur.execute("SELECT status FROM campaigns WHERE id=%s",(res["campaign_id"],)); st=cur.fetchone()[0]; c.close()
ok("campagne close (budget épuisé)", st=='closed', st)

# ---- S5 : campagne tout-ou-rien (budget < bonus -> stop, rien versé) ----
print("\nS5 · Campagne tout-ou-rien — budget 1€ < bonus 5€")
E.seed()
E.record_purchase(500,400,"0.02","CARREFOUR",datetime(2026,7,5))
E.record_purchase(300,400,"0.02","CARREFOUR",datetime(2026,7,5))  # David aussi, pour + de CIC
E.monthly_batch("2026-07", datetime(2026,7,5))
cic0=E.cic_balance(E.conn().cursor())
E.campaign_create("Beauté",20,"value","5.00","1.00",None)   # bonus 5, budget 1
before=E.wallet(410)  # Sophie, score Beauté 0 -> éligible
aw=E.campaign_award(410,100,"SEPHORA",datetime(2026,7,20))
ok("aucun versement (stopped_budget)", aw and aw.get("status")=="stopped_budget", aw)
ok("solde Sophie inchangé", eq(E.wallet(410),before))
cic1=E.cic_balance(E.conn().cursor())
ok("reliquat (1€) rendu à la CIC", eq(cic1,cic0), (cic1,cic0))

print("\n"+"="*66); print(f"  RÉSULTAT : {PASS} OK, {FAIL} échec(s)"); print("="*66)
import sys; sys.exit(1 if FAIL else 0)
