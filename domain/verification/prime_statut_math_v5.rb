# frozen_string_literal: true

# Preuve : le moteur Ruby PrimeStatutMath reproduit la grille validee (prime_ideal.py)
# et le split budget V5 somme a 100%.
require "bigdecimal"
require_relative "../app/services/prime_statut_math"

# --- split budget V5 ---
rates = { p: "0.40", ps: "0.05", sp: "0.20", co: "0.15", fo: "0.125", gl: "0.075" }
somme = rates.values.map { |v| BigDecimal(v) }.sum
raise "split != 100%" unless somme == BigDecimal("1.0")
puts "split budget V5 = #{somme.to_s('F')} (100%) OK"

# --- reproduction de la grille "forts rares" ---
n = 20; big_n = 5000.0; total = 50_000.0; panier = 80.0
ctaux = (0.5 * 0.015) + (0.3 * 0.02) + (0.2 * 0.04)
w = (1..n).map { |l| 0.80**(l - 1) }; s = w.sum
membres = w.map { |x| big_n * x / s }
act = (1..n).map { |l| 0.5 + ((l - 1) / 19.0) }
vv = (0...n).map { |i| membres[i] * act[i] }; vs = vv.sum
ventes = vv.map { |x| total * x / vs }
bl = [BigDecimal(0)] + (0...n).map { |i| BigDecimal((ventes[i] * panier * ctaux).to_s) }

res = PrimeStatutMath.solve(b_l: bl, poche_rate: BigDecimal("0.05"),
                            pas: BigDecimal("0.005"), plafond: BigDecimal("0.60"))
taux = (1..n).map { |l| ((BigDecimal("0.40") + res[:majorations][l]) * 100).round(1) }
attendu = [40.0, 40.5, 41.0, 42.0, 43.0, 44.5, 45.5, 47.0, 48.5, 49.5,
           51.0, 52.5, 54.0, 55.5, 57.5, 59.0, 60.5, 62.5, 64.5, 66.0].map { |x| BigDecimal(x.to_s) }
puts "p deduit = #{format('%.3f', res[:p])} (attendu ~1.34)"
puts "grille   = #{taux.map { |t| format('%.1f', t) }.join(' ')}"
raise "grille != attendue" unless taux == attendu

demi = (1..n).all? { |l| v = (BigDecimal("0.40") + res[:majorations][l]) * 100; ((v * 2) - (v * 2).round).abs < 1e-9 }
crois = (1...n).all? { |i| res[:majorations][i + 1] >= res[:majorations][i] }
raise "grille non conforme (0,5 / croissance)" unless demi && crois
poche = bl.sum * BigDecimal("0.05")
raise "depassement poche" unless res[:distributed] <= poche
puts "multiples 0,5 + croissant + sans depassement OK"
puts "TOUT VERT"
