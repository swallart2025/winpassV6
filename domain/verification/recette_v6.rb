# frozen_string_literal: true

# ============================================================================
# RECETTE V6 (Phase 1) — CASHBACK + ENRÔLEMENT + FRAUDE.
# S'exécute sur l'APPLICATION RÉELLE (vrais moteurs, vraie base). À lancer :
#
#   docker compose exec app bundle exec rails runner verification/recette_v6.rb
#
# Elle joue des scénarios de bout en bout sur des membres de TEST dédiés (ids
# 9100+, e-mails @recette.winpass), affiche [PASS]/[FAIL] AVEC LES VRAIS CHIFFRES,
# et se NETTOIE au départ pour être rejouable à l'infini.
#
# Ce qu'elle prouve (22 contrôles) :
#   Cashback : le socle 40 % alimente le solde « en attente » ; conversion au
#   seuil (20 €) et sur cadence (hebdo) ; conversion manuelle ; compteur des
#   autres poches ; parrainage reçu ; le cœur Earn (wallet) n'est pas altéré.
#   Enrôlement : 1er achat daté ; éligibilité « 15 jours » ; OTP ; invitation ;
#   CGU/CGV obligatoires ; création d'adhésion ; import de masse.
#   Fraude : blocage du parrain, incidence sur l'éligibilité, levée/confirmation.
#   Confidentialité : la vue parrain ne divulgue jamais la commission.
# ============================================================================

require "bigdecimal"

$pass = 0
$fail = 0

def check(label)
  ok = yield
  puts((ok ? "  [PASS] " : "  [FAIL] ") + label)
  ok ? ($pass += 1) : ($fail += 1)
rescue => e
  puts "  [FAIL] #{label}  ->  #{e.class}: #{e.message}"
  $fail += 1
end

def n2(v) = format("%.2f", v.to_f)

# --- Bornes de test ---------------------------------------------------------
IDS      = (9100..9199).to_a
CB1, CB2, CB3, CB4, CB5 = 9101, 9102, 9103, 9104, 9105
SP, FL   = 9110, 9111
EP, EP2  = 9120, 9121
TEST_MAIL = "recette.winpass"

def purchase(member_id, order_amount, rate: BigDecimal("0.05"), key:, at: Time.current, merchant: "CARREFOUR")
  PurchaseEngine.call(
    order: { id: key, member_id: member_id, order_amount: order_amount,
             commission_rate: rate, merchant_id: merchant, delivered_at: at },
    event_key: key
  )
end

# --- Nettoyage (rejouabilité) ----------------------------------------------
def cleanup!
  CashbackConversion.where(member_id: IDS).delete_all
  CashbackAccount.where(member_id: IDS).delete_all
  MemberPocheCounter.where(member_id: IDS).delete_all
  FraudCase.where(member_id: IDS).or(FraudCase.where(reported_member_id: IDS)).delete_all
  EnrollmentInvitation.where("email LIKE ?", "%@#{TEST_MAIL}").delete_all
  OtpChallenge.where("email LIKE ?", "%@#{TEST_MAIL}").delete_all
  WalletStatement.where(member_id: IDS).delete_all
  WalletLot.where(member_id: IDS).delete_all
  EarnLedger.where(member_id: IDS).delete_all
  PoolContribution.where(source_member_id: IDS).delete_all
  Payment.where(member_id: IDS).delete_all rescue nil
  ProcessedEvent.where("event_key LIKE ?", "RECV6-%").delete_all
  MemberSponsorship.where(member_id: IDS).or(MemberSponsorship.where(sponsor_member_id: IDS)).delete_all
  Wallet.where(member_id: IDS).delete_all
  # Adhésions créées par l'enrôlement (member_id >= 10000, e-mail de test)
  new_ids = Membership.where("email LIKE ?", "%@#{TEST_MAIL}").pluck(:member_id)
  (new_ids).each do |mid|
    CashbackAccount.where(member_id: mid).delete_all
    MemberPocheCounter.where(member_id: mid).delete_all
    Wallet.where(member_id: mid).delete_all
    MemberSponsorship.where(member_id: mid).delete_all
  end
  Membership.where("email LIKE ?", "%@#{TEST_MAIL}").delete_all
  Membership.where(member_id: IDS).delete_all
end

# --- Config cashback garantie ----------------------------------------------
if CashbackConfig.current.none?
  CashbackConfig.find_or_create_by!(version_label: "CB-V6-2026") do |c|
    c.threshold_cents = 2000
    c.cadence_days = 7
    c.effective_from = Time.current
  end
end
CFG = CashbackConfig.current!

puts "=" * 76
puts "RECETTE V6 — cashback / enrôlement / fraude  (seuil #{n2(CFG.threshold_amount)} € · cadence #{CFG.cadence_days} j)"
puts "=" * 76
cleanup!

# ---------------------------------------------------------------------------
puts "\n== 1. CASHBACK — alimentation du solde « en attente » (socle 40 %) =="
# base = 100 × 0,05 = 5 € ; socle 40 % = 2,00 € (sous le seuil de 20 €)
r = purchase(CB1, 100, key: "RECV6-CB1")
acct1 = CashbackAccount.find_by(member_id: CB1)
puts "  achat 100 € @5% -> base 5,00 € ; en attente=#{n2(acct1&.pending_amount)} ; crédit=#{n2(acct1&.credit_winpass_amount)}"
check("1. l'achat crédite le solde en attente") { acct1 && acct1.pending_amount.positive? }
check("2. en attente = 40 % de la commission (2,00 €)") { acct1 && acct1.pending_amount == BigDecimal("2") }
check("3. sous le seuil : aucune conversion (crédit Winpass = 0)") { acct1.credit_winpass_amount.zero? }
check("4. le cœur Earn n'est pas altéré : wallet crédité du socle (2,00 €)") do
  Wallet.find_by(member_id: CB1).available_balance == BigDecimal("2")
end

# ---------------------------------------------------------------------------
puts "\n== 2. CASHBACK — conversion automatique au SEUIL =="
# base = 2000 × 0,05 = 100 € ; socle 40 % = 40 € >= seuil 20 € -> conversion
purchase(CB2, 2000, key: "RECV6-CB2")
acct2 = CashbackAccount.find_by(member_id: CB2)
conv2 = CashbackConversion.where(member_id: CB2, trigger: "threshold")
puts "  achat 2000 € @5% -> socle 40,00 € ; en attente=#{n2(acct2.pending_amount)} ; crédit=#{n2(acct2.credit_winpass_amount)} ; conversions=#{conv2.count}"
check("5. au-dessus du seuil : conversion automatique (crédit = 40,00 €)") { acct2.credit_winpass_amount == BigDecimal("40") }
check("6. le solde en attente est vidé après conversion") { acct2.pending_amount.zero? }
check("7. une ligne de conversion 'threshold' est journalisée") { conv2.count == 1 }
check("8. cumul à vie conservé (40,00 €)") { acct2.lifetime_cashback == BigDecimal("40") }

# ---------------------------------------------------------------------------
puts "\n== 3. CASHBACK — compteur des AUTRES poches (informationnel) =="
cnt2 = MemberPocheCounter.find_by(member_id: CB2)
# base 100 € : prime_statut 5% =5 ; comportemental 15% =15 ; grands_leaders 7,5% =7,5 ; fonctionnement 12,5% =12,5
puts "  autres poches CB2 : PS=#{n2(cnt2.prime_statut)} GG=#{n2(cnt2.comportemental)} BAT=#{n2(cnt2.grands_leaders)} FCT=#{n2(cnt2.fonctionnement)}"
check("9. Prime de Statut comptée (5 % = 5,00 €)") { cnt2.prime_statut == BigDecimal("5") }
check("10. Grande Galerie comptée (15 % = 15,00 €)") { cnt2.comportemental == BigDecimal("15") }
check("11. total autres poches = 40,00 € (5+15+7,5+12,5)") { cnt2.total_autres == BigDecimal("40") }

# ---------------------------------------------------------------------------
puts "\n== 4. CASHBACK — parrainage reçu au compteur du parrain =="
MemberSponsorship.create!(member_id: FL, sponsor_member_id: SP, effective_from: 30.days.ago, reason: "signup")
Membership.find_or_create_by!(member_id: SP) { |m| m.status = "active"; m.display_name = "Parrain test" }
Wallet.find_or_create_by!(member_id: SP)
purchase(FL, 1000, key: "RECV6-FL1") # base 50 ; pool 20% =10 ; G1 = 10 × 1,0 (1 seul parrain)
cntSP = MemberPocheCounter.find_by(member_id: SP)
puts "  filleul FL achète 1000 € -> parrain SP parrainage_reçu=#{n2(cntSP&.parrainage_recu)}"
check("12. le compteur « parrainage reçu » du parrain est alimenté") { cntSP && cntSP.parrainage_recu.positive? }

# ---------------------------------------------------------------------------
puts "\n== 5. CASHBACK — conversion MANUELLE =="
purchase(CB3, 100, key: "RECV6-CB3") # pending 2,00 €
rm = ConversionEngine.convert_now!(member_id: CB3)
acct3 = CashbackAccount.find_by(member_id: CB3)
puts "  convert_now! -> statut=#{rm.status} montant=#{n2(rm.amount)} ; en attente=#{n2(acct3.pending_amount)} crédit=#{n2(acct3.credit_winpass_amount)}"
check("13. la conversion manuelle vide l'attente vers le Crédit Winpass") { acct3.pending_amount.zero? && acct3.credit_winpass_amount == BigDecimal("2") }
check("14. ligne de conversion 'manual' journalisée") { CashbackConversion.where(member_id: CB3, trigger: "manual").count == 1 }

# ---------------------------------------------------------------------------
puts "\n== 6. CASHBACK — batch de CADENCE (hebdo) =="
purchase(CB4, 100, key: "RECV6-CB4") # pending 2,00 € (sous seuil)
CashbackAccount.where(member_id: CB4).update_all(last_conversion_at: (CFG.cadence_days + 1).days.ago)
purchase(CB5, 100, key: "RECV6-CB5") # pending 2,00 € (sous seuil)
CashbackAccount.where(member_id: CB5).update_all(last_conversion_at: Time.current) # cadence NON échue
ConversionEngine.run_cadence!
acct4 = CashbackAccount.find_by(member_id: CB4)
acct5 = CashbackAccount.find_by(member_id: CB5)
puts "  après batch : CB4(échu) attente=#{n2(acct4.pending_amount)} crédit=#{n2(acct4.credit_winpass_amount)} | CB5(non échu) attente=#{n2(acct5.pending_amount)}"
check("15. cadence échue : reliquat converti même sous le seuil") { acct4.pending_amount.zero? && acct4.credit_winpass_amount == BigDecimal("2") }
check("16. cadence non échue : rien n'est converti") { acct5.pending_amount == BigDecimal("2") && acct5.credit_winpass_amount.zero? }

# ---------------------------------------------------------------------------
puts "\n== 7. ENRÔLEMENT — 1er achat & éligibilité « 15 jours » =="
# EP : 1er achat il y a 20 jours -> éligible ; EP2 : il y a 5 jours -> trop récent
purchase(EP,  100, key: "RECV6-EP1", at: 20.days.ago)
purchase(EP2, 100, key: "RECV6-EP2", at: 5.days.ago)
mEP = Membership.find_by(member_id: EP)
puts "  EP first_purchase_at=#{mEP.first_purchase_at&.strftime('%Y-%m-%d')} (il y a ~20 j)"
check("17. la date du 1er achat est mémorisée") { mEP.first_purchase_at.present? }
check("18. membre sans achat : non éligible (no_purchase)") { EnrollmentEligibility.check(member_id: 9199).reason == "no_purchase" }
check("19. 1er achat < 15 j : non éligible (too_recent, jours restants > 0)") do
  e = EnrollmentEligibility.check(member_id: EP2); !e.eligible && e.reason == "too_recent" && e.days_remaining.to_i.positive?
end
check("20. 1er achat >= 15 j : éligible") { EnrollmentEligibility.check(member_id: EP).eligible }

# ---------------------------------------------------------------------------
puts "\n== 8. ENRÔLEMENT — OTP, invitation, CGU/CGV, création, import =="
iss = OtpService.issue!(email: "otp@#{TEST_MAIL}")
bad = OtpService.verify!(email: "otp@#{TEST_MAIL}", code: "000000")
good = OtpService.verify!(email: "otp@#{TEST_MAIL}", code: iss.code)
check("21. OTP : bon code accepté, mauvais code refusé") { good.status == :ok && bad.status == :invalid }

inv_ok  = EnrollmentService.invite!(sponsor_member_id: EP,  email: "f1@#{TEST_MAIL}")
inv_ko  = EnrollmentService.invite!(sponsor_member_id: EP2, email: "f2@#{TEST_MAIL}")
puts "  invitation parrain éligible=#{inv_ok.status} | parrain trop récent=#{inv_ko.status}/#{inv_ko.reason}"
check("22. invitation : parrain éligible OK, parrain non éligible refusé") { inv_ok.status == :sent && inv_ko.status == :ineligible }

no_cgu = EnrollmentService.accept!(token: inv_ok.invitation.token, display_name: "Filleul 1", cgu: true, cgv: false)
acc    = EnrollmentService.accept!(token: inv_ok.invitation.token, display_name: "Filleul 1", cgu: true, cgv: true)
puts "  acceptation sans CGV=#{no_cgu.status} | avec CGU+CGV=#{acc.status} -> membre ##{acc.membership&.member_id}"
check("23. CGU/CGV obligatoires (refus si l'une manque)") { no_cgu.status == :cgu_cgv_required }
check("24. acceptation CGU+CGV : adhésion + portefeuille + parrainage créés") do
  acc.status == :accepted && Wallet.exists?(member_id: acc.membership.member_id) &&
    MemberSponsorship.active.exists?(member_id: acc.membership.member_id, sponsor_member_id: EP)
end

created = EnrollmentService.import_mass!(rows: [
  { email: "m1@#{TEST_MAIL}", sponsor_member_id: EP },
  { email: "m2@#{TEST_MAIL}", sponsor_member_id: EP }
])
check("25. import de masse : 2 invitations créées") { created == 2 && EnrollmentInvitation.where(source: "mass_import").where("email LIKE ?", "%@#{TEST_MAIL}").count == 2 }

# ---------------------------------------------------------------------------
puts "\n== 9. FRAUDE — blocage du parrain, éligibilité, levée =="
op = FraudService.open!(reported_member_id: FL, reason: "e-bon fictif")
mSP = Membership.find_by(member_id: SP)
puts "  dossier ouvert sur filleul FL -> parrain bloqué=#{mSP.blocked} (##{op.fraud_case&.id})"
check("26. ouverture : le parrain du filleul est bloqué") { op.status == :opened && mSP.reload.blocked? }
check("27. un parrain bloqué n'est plus éligible à enrôler") { EnrollmentEligibility.check(member_id: SP).reason == "blocked" }

FraudService.clear!(fraud_case_id: op.fraud_case.id)
check("28. levée (blanchi) : le blocage est retiré") { !Membership.find_by(member_id: SP).blocked? }

# ---------------------------------------------------------------------------
puts "\n== 10. CONFIDENTIALITÉ — la vue parrain ne divulgue pas la commission =="
pv = ParrainView.build(member_id: SP)
json = pv.to_json
puts "  vue parrain SP : filleuls directs=#{pv[:direct].size} ; niveaux suivants=#{pv[:deeper][:total]}"
check("29. filleuls directs nommés, sans montant individuel") do
  pv[:direct].all? { |f| (f.keys - %i[member_id display_name active]).empty? }
end
check("30. aucune 'commission' n'apparaît dans la vue parrain") { !json.downcase.include?("commission") }

# ---------------------------------------------------------------------------
puts "\n" + ("=" * 76)
puts "RÉSULTAT V6 : #{$pass} PASS / #{$fail} FAIL"
puts($fail.zero? ? "TOUT VERT — cashback, enrôlement, fraude et confidentialité prouvés sur l'appli réelle." : "ÉCHECS — voir ci-dessus.")
puts "=" * 76
cleanup! # on laisse la base propre
exit($fail.zero? ? 0 : 1)
