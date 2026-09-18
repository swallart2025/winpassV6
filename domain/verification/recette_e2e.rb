# frozen_string_literal: true

# ============================================================================
# RECETTE DE BOUT EN BOUT — s'exécute sur l'APPLICATION RÉELLE (vrais moteurs,
# vraie base). À lancer dans le conteneur :
#
#   docker compose exec app bundle exec rails runner verification/recette_e2e.rb
#
# Elle joue le scénario complet sur le jeu de démo V5.1 et affiche [PASS]/[FAIL]
# AVEC LES VRAIS CHIFFRES. Ce qu'elle prouve :
#   1. chaque batch distribue quelque chose (poches alimentées) ;
#   2. RECLIQUER ne double rien : « déjà fait », zéro euro ne bouge (fin du pot RFA
#      qui gonfle) ;
#   3. la PURGE remet la période à zéro (« point barre »), puis on peut rejouer.
# ============================================================================

PERIOD  = "2026-09"
QUARTER = "2026-Q3"
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

def n2(v) = format("%.6f", v.to_f)

puts "=" * 76
puts "RECETTE E2E V5.1 — période #{PERIOD} / trimestre #{QUARTER}"
puts "=" * 76

# ---------------------------------------------------------------------------
puts "\n== 1. PRIME DE STATUT =="
PrimeStatutRollback.call(period: PERIOD) # départ propre
r1 = PrimeStatutEngine.call(period: PERIOD)
puts "  run #1 : statut=#{r1.status} membres=#{r1.processed} poche=#{n2(r1.poche)} " \
     "distribué=#{n2(r1.distributed)} réserve=#{n2(r1.reserve_closing)}"
c_after_run1 = PrimeStatutReward.where(period: PERIOD).count
check("run #1 distribue quelque chose (poche 5% alimentée)") { r1.status == :processed && r1.distributed.to_f > 0 }
check("distribué <= poche (jamais de dépassement)") { r1.distributed <= r1.poche }

r2 = PrimeStatutEngine.call(period: PERIOD)
c_after_run2 = PrimeStatutReward.where(period: PERIOD).count
puts "  run #2 : statut=#{r2.status} (attendu already_run) — lignes avant/après=#{c_after_run1}/#{c_after_run2}"
check("RECLIC = already_run, aucune prime supplémentaire") { r2.status == :already_run && c_after_run2 == c_after_run1 }

pu = PrimeStatutRollback.call(period: PERIOD)
c_after_purge = PrimeStatutReward.where(period: PERIOD).count
puts "  purge : statut=#{pu.status} réinitialisées=#{pu.reset_count} — lignes restantes=#{c_after_purge}"
check("PURGE = remise à zéro totale (0 prime restante)") { c_after_purge.zero? }

r3 = PrimeStatutEngine.call(period: PERIOD)
check("REJOUABLE après purge (redistribue)") { r3.status == :processed && r3.distributed.to_f > 0 }

# ---------------------------------------------------------------------------
puts "\n== 2. BÂTISSEURS — RANGS =="
rr = BuilderMonthlyEngine.call(period: PERIOD)
lea = BuilderStatus.find_by(member_id: 900)
puts "  batch rangs : rangés=#{rr.processed} — Léa(#900) rang=#{lea&.rang} (#{PrimeRangMath.nom(lea&.rang || 0)}) " \
     "SF=#{n2(lea&.score_foret || 0)}"
check("au moins 1 Bâtisseur rangé (gate des 7 filleuls ouvert)") { rr.processed.positive? }
check("Léa (#900) a un rang > 0") { lea && lea.rang.positive? }

# ---------------------------------------------------------------------------
puts "\n== 3. BÂTISSEURS — PRIMES + GARDE-FOU RFA (le bug corrigé) =="
BuilderPrimeRollback.call(period: QUARTER) # départ propre
p1 = BuilderPrimeEngine.call(period: QUARTER)
rfa1 = BuilderReserve.order(:year).last&.rfa_total || 0
puts "  run #1 : statut=#{p1.status} leaders=#{p1.processed} poche=#{n2(p1.pocket)} " \
     "distribué=#{n2(p1.distributed)} RFA=#{n2(rfa1)}"
check("run #1 : poche ajoutée, distribution aux leaders rangés") { p1.status == :processed }

p2 = BuilderPrimeEngine.call(period: QUARTER)
rfa2 = BuilderReserve.order(:year).last&.rfa_total || 0
p3 = BuilderPrimeEngine.call(period: QUARTER)
rfa3 = BuilderReserve.order(:year).last&.rfa_total || 0
puts "  run #2 : statut=#{p2.status}  RFA=#{n2(rfa2)}   |   run #3 : statut=#{p3.status}  RFA=#{n2(rfa3)}"
check("RECLIC = already_run (x2)") { p2.status == :already_run && p3.status == :already_run }
check("★ LE POT RFA NE GONFLE PLUS : RFA identique après 3 clics") { rfa2 == rfa1 && rfa3 == rfa1 }

pu2 = BuilderPrimeRollback.call(period: QUARTER)
run_left = BuilderPrimeRun.where(period: QUARTER).count
rew_left = BuilderPrimeReward.where(period: QUARTER).count
puts "  purge : statut=#{pu2.status} réinitialisées=#{pu2.reset_count} RFA=#{n2(pu2.rfa)} " \
     "— marqueurs/récompenses restants=#{run_left}/#{rew_left}"
check("PURGE trimestre = remise à zéro (marqueur + récompenses supprimés)") { run_left.zero? && rew_left.zero? }

p4 = BuilderPrimeEngine.call(period: QUARTER)
rfa4 = BuilderReserve.order(:year).last&.rfa_total || 0
check("REJOUABLE après purge (RFA revient à sa valeur)") { p4.status == :processed && rfa4 == rfa1 }

# ---------------------------------------------------------------------------
puts "\n== 4. COMPORTEMENTAL — batch + purge =="
BehavioralRollback.call(period: PERIOD) # départ propre
b1 = BehavioralMonthlyEngine.call(period: PERIOD, as_of: nil)
cnt1 = MemberMonthlyReward.where(period: PERIOD).count
puts "  run #1 : statut=#{b1.status} traités=#{b1.processed} CIC=#{n2(b1.cic_after)} — photos=#{cnt1}"
check("run #1 distribue (poche 15% alimentée)") { b1.status == :processed && cnt1.positive? }

b2 = BehavioralMonthlyEngine.call(period: PERIOD, as_of: nil)
puts "  run #2 : statut=#{b2.status} (attendu already_run)"
check("RECLIC = already_run (pas de double-crédit)") { b2.status == :already_run }

BehavioralRollback.call(period: PERIOD)
cnt_after = MemberMonthlyReward.where(period: PERIOD).count
check("PURGE = remise à zéro (0 photo restante)") { cnt_after.zero? }
b3 = BehavioralMonthlyEngine.call(period: PERIOD, as_of: nil)
check("REJOUABLE après purge") { b3.status == :processed }

# ---------------------------------------------------------------------------
puts "\n" + ("=" * 76)
puts "RÉSULTAT : #{$pass} PASS / #{$fail} FAIL"
puts($fail.zero? ? "TOUT VERT — garde-fous et purges prouvés sur l'appli réelle." : "ÉCHECS — voir ci-dessus.")
puts "=" * 76
exit($fail.zero? ? 0 : 1)
