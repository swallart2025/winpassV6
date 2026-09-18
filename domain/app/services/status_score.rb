# frozen_string_literal: true

require "bigdecimal"

# Score de STATUT ACHETEUR (0..100) d'un membre sur un MOIS donné.
# Distinct du score comportemental (qui, lui, décroît dans le temps).
#
#   Score = 0,25·Fréquence + 0,35·Diversité + 0,25·Animation + 0,15·Montant
#   Animation = (Parrainage + Participation) / 2
#
# Chaque critère est ramené sur 0/25/50/75/100 par des bandes (spec §4). Les
# achats comptent sur le mois (pas de décroissance). Les bandes et poids sont
# des constantes documentées ici (versionnables ultérieurement en config).
class StatusScore
  WEIGHTS = { frequence: 25, diversite: 35, animation: 25, montant: 15 }.freeze
  QUALIFYING_MIN_EUR = BigDecimal("20") # un achat "fréquent" vaut >= 20 €
  SPONSEE_QUALIF_LEVEL = 5              # un filleul compte s'il est >= niveau 5

  # bandes : valeur -> seuils croissants ; note = 0,25,50,75,100 selon la tranche atteinte
  BANDS = {
    frequence:     [2, 4, 7, 10],       # nb achats >= 20 € / mois
    diversite:     [2, 3, 5, 7],        # catégories actives / mois
    montant:       [100, 300, 600, 1000], # € qualifiants / mois
    parrainage:    [1, 6, 9, 12],       # filleuls qualifiés
    participation: [10, 30, 50, 70]     # % de challenges / an
  }.freeze

  def self.note(value, thresholds)
    n = thresholds.count { |t| value >= t }
    [0, 25, 50, 75, 100][n]
  end

  # @return [Hash] détail + score entier (0..100)
  def self.for(member_id, period)
    y, m = period.split("-").map(&:to_i)
    from = Time.zone.local(y, m, 1)
    to   = from.end_of_month

    freq = note(freq_count(member_id, from, to), BANDS[:frequence])
    div  = note(distinct_categories(member_id, from, to), BANDS[:diversite])
    mont = note(qualifying_amount(member_id, from, to).to_i, BANDS[:montant])
    parr = note(qualified_sponsees(member_id, to), BANDS[:parrainage])
    part = note(participation_pct(member_id, from, to), BANDS[:participation])
    anim = (parr + part) / 2.0

    score = (WEIGHTS[:frequence] * freq + WEIGHTS[:diversite] * div +
             WEIGHTS[:animation] * anim + WEIGHTS[:montant] * mont) / 100.0
    { frequence: freq, diversite: div, montant: mont, parrainage: parr,
      participation: part, animation: anim, score: score.ceil }
  end

  # --- mesures (achats PERSONNELS livrés dans le mois) ------------------------
  def self.month_scope(member_id, from, to)
    EarnLedger.where(member_id: member_id, earn_type: "personal")
              .where("delivered_at >= ? AND delivered_at <= ?", from, to)
              .where("order_amount IS NOT NULL")
  end

  def self.freq_count(member_id, from, to)
    month_scope(member_id, from, to).where("order_amount >= ?", QUALIFYING_MIN_EUR).count
  end

  def self.distinct_categories(member_id, from, to)
    month_scope(member_id, from, to)
      .joins("JOIN merchant_categories mc ON mc.merchant_id = earn_ledgers.merchant_id")
      .distinct.count("mc.category")
  end

  def self.qualifying_amount(member_id, from, to)
    month_scope(member_id, from, to).sum(:order_amount)
  end

  # Filleuls directs actifs à la date `to`, dont le NIVEAU tenu >= seuil (pas de
  # circularité : on lit le statut déjà arrêté).
  def self.qualified_sponsees(member_id, to)
    sponsee_ids = MemberSponsorship
                  .where(sponsor_member_id: member_id)
                  .where("effective_from <= ? AND (effective_to IS NULL OR effective_to > ?)", to, to)
                  .pluck(:member_id)
    return 0 if sponsee_ids.empty?

    MemberStatus.where(member_id: sponsee_ids)
                .where("niveau_tenu >= ?", SPONSEE_QUALIF_LEVEL).count
  end

  # Participation aux challenges : source non encore câblée (spec §11) -> 0.
  def self.participation_pct(_member_id, _from, _to)
    0
  end
end
