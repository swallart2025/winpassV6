# frozen_string_literal: true

# Preuves Batisseurs (pures) : prime de rang (spec 3.2-bis), mapping SF->rang,
# agregation trimestrielle + RFA.
require "bigdecimal"
require_relative "../app/services/prime_rang_math"
require_relative "../app/services/builder_score"

fail_any = false
def check(label, ok)
  puts "  #{ok ? 'OK  ' : 'ECHEC'} #{label}"
  ok
end

puts "== Prime de rang (spec 3.2-bis) =="
w3 = { 1 => BigDecimal("0.456621"), 2 => BigDecimal("0.319635"), 3 => BigDecimal("0.223744") }
up = [{ generation: 1, rang: 4 }, { generation: 2, rang: 3 }, { generation: 3, rang: 1 }]
r  = PrimeRangMath.majorations(upline: up, weights: w3, base: BigDecimal("8"))
rfa = PrimeRangMath.rfa_residual(base: BigDecimal("8"), distributed: r[:distributed], pocket_rate: BigDecimal("0.075"))
fail_any |= !check("distribue 0.339361", r[:distributed].round(6) == BigDecimal("0.339361"))
fail_any |= !check("RFA 0.260639", rfa == BigDecimal("0.260639"))
fail_any |= !check("borne <= 0.80 (10% x B)", r[:distributed] <= BigDecimal("0.80"))

puts "== Mapping SF -> rang =="
[[80, 3, 0], [4, 7, 1], [6, 10, 2], [12, 10, 3], [25, 10, 4], [40, 10, 5], [55, 10, 6]].each do |sf, q, exp|
  fail_any |= !check("SF=#{sf} qualif=#{q} -> #{exp} (#{PrimeRangMath.nom(exp)})",
                     BuilderScore.rang_from(BigDecimal(sf.to_s), q) == exp)
end

puts "== Agregation trimestrielle + RFA (2 achats) =="
pocket = BigDecimal(0); distributed = BigDecimal(0)
[[BigDecimal("8"), w3, [{ generation: 1, rang: 4 }, { generation: 2, rang: 3 }, { generation: 3, rang: 1 }]],
 [BigDecimal("5"), { 1 => BigDecimal("0.588235"), 2 => BigDecimal("0.411765") },
  [{ generation: 1, rang: 6 }, { generation: 2, rang: 5 }]]].each do |base, w, upl|
  pocket += base * BigDecimal("0.075")
  PrimeRangMath.majorations(upline: upl, weights: w, base: base)[:majorations].each_value { |m| distributed += m }
end
fail_any |= !check("poche = 0.975000", pocket.round(6) == BigDecimal("0.975000"))
fail_any |= !check("RFA >= 0 (pyramide normale)", (pocket - distributed) >= 0)

raise "ECHEC Batisseurs" if fail_any
puts "TOUT VERT"
