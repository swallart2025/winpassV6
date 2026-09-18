# frozen_string_literal: true

require "bigdecimal"

# Calcul PUR de la Prime de performance collective de Statut (aucune dépendance
# Rails — testable en isolation). Reproduit l'algorithme validé (prime20.py) :
#
#   1. `p` DÉDUIT par équation : Σ (l−1)^p · B_l = (poche_rate ÷ pas) · R
#      (bissection ; le plus petit pas vaut alors `pas`).
#   2. Majorations continues m*_l = min(plafond, k·(l−1)^p), k = poche ÷ Σ w_l B_l,
#      avec water-filling sur le plafond.
#   3. Projection sur la grille `pas` au PLUS FORT RESTE (Hamilton), sans dépasser
#      le budget (poche + réserve reportée) ; croissant, sous plafond ; reliquat
#      → réserve.
#
# Entrée : b_l = tableau des assiettes par niveau (indices 1..n ; l'indice 0 ignoré).
# Sortie : { p:, majorations:(1..n)->BigDecimal, distributed:, reserve_out:, base_poche: }
class PrimeStatutMath
  def self.solve(b_l:, poche_rate:, pas:, plafond:, reserve_in: BigDecimal(0))
    n = b_l.length - 1
    bl = (0..n).map { |i| BigDecimal(b_l[i].to_s) }
    r_total = (1..n).sum { |l| bl[l] }
    base = (r_total * poche_rate)
    return empty(n, reserve_in) if r_total <= 0

    p   = deduce_p(bl, n, poche_rate, pas, r_total)
    mstar = continu(bl, n, p, base, plafond)                 # fractions (Float)
    project(bl, n, mstar, pas, plafond, base + reserve_in, p)
  end

  # --- 1) p déduit : Σ (l−1)^p B_l = (poche/pas) R --------------------------
  def self.deduce_p(bl, n, poche_rate, pas, r_total)
    target = (poche_rate / pas).to_f * r_total.to_f
    f = ->(p) { (1..n).sum { |l| ((l - 1)**p) * bl[l].to_f } - target }
    lo = 0.2
    hi = 6.0
    60.times do
      mid = (lo + hi) / 2
      f.call(mid) > 0 ? hi = mid : lo = mid
    end
    (lo + hi) / 2
  end

  # --- 2) continu + water-filling (fractions) -------------------------------
  def self.continu(bl, n, p, base, plafond)
    plaf = plafond.to_f
    w = (0..n).map { |i| i.zero? ? 0.0 : ((i - 1)**p) } # w[l] = (l-1)^p ; w[0] ignoré
    m = Array.new(n + 1, 0.0)
    free = (1..n).to_a
    fixed = 0.0
    loop do
      denom = free.sum { |l| w[l] * bl[l].to_f }
      break if denom <= 0

      k = (base.to_f - fixed) / denom
      cand = free.to_h { |l| [l, k * w[l]] }
      over = cand.select { |_l, v| v > plaf + 1e-15 }.keys
      if over.empty?
        free.each { |l| m[l] = cand[l] }
        break
      end
      over.each { |l| m[l] = plaf; fixed += plaf * bl[l].to_f; free.delete(l) }
    end
    m
  end

  # --- 3) projection grille `pas`, plus fort reste --------------------------
  def self.project(bl, n, mstar, pas, plafond, budget, p)
    pasf = pas.to_f
    capu = (plafond / pas).round
    u  = (0..n).map { |l| l.zero? ? 0.0 : mstar[l] / pasf }
    fl = (0..n).map { |l| l.zero? ? 0 : u[l].floor }
    fr = (0..n).map { |l| l.zero? ? 0.0 : (u[l] - fl[l]) }
    x  = fl.dup
    spent = (1..n).sum { |l| pas * x[l] * bl[l] }
    rho   = budget - spent
    loop do
      best = nil
      (1..n).each do |l|
        next if x[l] != fl[l] || fr[l] <= 1e-9 || x[l] + 1 > capu
        next if l < n && x[l] + 1 > x[l + 1]

        cost = pas * bl[l]
        next if cost > rho + BigDecimal("0.000000001")

        key = [fr[l].round(9), l]
        best = [key, l, cost] if best.nil? || (key <=> best[0]) > 0
      end
      break if best.nil?

      _key, l, cost = best
      x[l] += 1
      rho -= cost
    end
    majorations = (0..n).map { |l| l.zero? ? BigDecimal(0) : pas * x[l] }
    distributed = (1..n).sum { |l| majorations[l] * bl[l] }
    { p: p, majorations: majorations, distributed: distributed,
      reserve_out: (budget - distributed), base_poche: nil }
  end

  def self.empty(n, reserve_in)
    { p: nil, majorations: Array.new(n + 1, BigDecimal(0)), distributed: BigDecimal(0),
      reserve_out: reserve_in, base_poche: BigDecimal(0) }
  end
end
