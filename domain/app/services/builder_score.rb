# frozen_string_literal: true

require "bigdecimal"

# Score Forêt (SF) et rang Bâtisseur d'un parrain (spec §3.3).
#
#   SF = ( Équipe + Arbre secondaire + Racines ) × Activité perso
#   rang = f(SF, nb filleuls qualifiés)   — gate : ≥ 7 filleuls qualifiés
#
# Équipe = filleuls directs (plafond 30 ; au-delà du 20e, 0,5 pt max), pondérés
# par le NIVEAU acheteur du filleul (Ruisseau≥5:0,4 · Rivière≥9:0,7 · Delta+≥13:1,0).
# Arbre secondaire = génération 2 (plafond 15 : 0,2/0,4/0,6). Racines = G3/G4
# (plafond 5 : 0,1/0,05). Activité perso = multiplicateur 1/0,85/0,5/0 selon la
# consommation du mois.
class BuilderScore
  GATE_QUALIFIED = 7
  QUALIF_LEVEL   = 5

  def self.team_pts(level)
    return BigDecimal("1.0") if level >= 13
    return BigDecimal("0.7") if level >= 9
    return BigDecimal("0.4") if level >= 5

    BigDecimal(0)
  end

  def self.arbre_pts(level)
    return BigDecimal("0.6") if level >= 13
    return BigDecimal("0.4") if level >= 9
    return BigDecimal("0.2") if level >= 5

    BigDecimal(0)
  end

  # Multiplicateur d'activité perso selon le montant qualifiant du mois.
  def self.activite_mult(qualifying_amount)
    a = qualifying_amount.to_i
    return BigDecimal("1.0")  if a >= 100
    return BigDecimal("0.85") if a >= 50
    return BigDecimal("0.5")  if a.positive?

    BigDecimal(0)
  end

  # rang à partir du SF et du nombre de filleuls qualifiés.
  def self.rang_from(sf, qualified)
    return 0 if qualified < GATE_QUALIFIED # Graine tant que le gate n'est pas ouvert

    s = sf.to_f
    return 6 if s >= 50   # Canopée
    return 5 if s >= 31   # Forêt
    return 4 if s >= 16   # Bois
    return 3 if s >= 8    # Bosquet
    return 2 if s >= 5    # Arbre

    1                     # Jeune Plant (gate ouvert)
  end

  # @return [Hash] { sf:, rang:, qualified:, team:, arbre:, racines:, activite: }
  def self.for(member_id, at)
    g1 = direct_sponsees(member_id, at)
    levels1 = levels_of(g1)
    qualified = levels1.count { |lv| lv >= QUALIF_LEVEL }

    # Équipe : points par filleul, triés décroissants, plafond 30, 0,5 max au-delà du 20e.
    pts1 = levels1.map { |lv| team_pts(lv) }.sort.reverse
    team = BigDecimal(0)
    pts1.first(30).each_with_index { |p, i| team += (i >= 20 ? [p, BigDecimal("0.5")].min : p) }

    g2 = sponsees_of_set(g1, at)
    arbre = levels_of(g2).first(15).sum(BigDecimal(0)) { |lv| arbre_pts(lv) }

    g3 = sponsees_of_set(g2, at)
    g4 = sponsees_of_set(g3, at)
    racines = BigDecimal(0)
    g3.first(5).each { racines += BigDecimal("0.1") }
    g4.first(5).each { racines += BigDecimal("0.05") }

    activite = activite_mult(qualifying_amount(member_id, at))
    sf = (team + arbre + racines) * activite
    { sf: sf, rang: rang_from(sf, qualified), qualified: qualified,
      team: team, arbre: arbre, racines: racines, activite: activite }
  end

  # --- accès réseau -----------------------------------------------------------
  def self.direct_sponsees(member_id, at)
    MemberSponsorship
      .where(sponsor_member_id: member_id)
      .where("effective_from <= ? AND (effective_to IS NULL OR effective_to > ?)", at, at)
      .pluck(:member_id)
  end

  def self.sponsees_of_set(ids, at)
    return [] if ids.empty?

    MemberSponsorship
      .where(sponsor_member_id: ids)
      .where("effective_from <= ? AND (effective_to IS NULL OR effective_to > ?)", at, at)
      .pluck(:member_id)
  end

  def self.levels_of(ids)
    return [] if ids.empty?

    h = MemberStatus.where(member_id: ids).pluck(:member_id, :niveau_tenu).to_h
    ids.map { |i| h[i] || 1 }
  end

  def self.qualifying_amount(member_id, at)
    from = at.beginning_of_month
    EarnLedger.where(member_id: member_id, earn_type: "personal")
              .where("delivered_at >= ? AND delivered_at <= ?", from, at)
              .where("order_amount >= ?", 20)
              .sum(:order_amount)
  end
end
