# frozen_string_literal: true

# Batch mensuel du rang Bâtisseur : Score Forêt -> rang, mis à jour dans
# builder_statuses. Montée immédiate ; la baisse est amortie par le multiplicateur
# d'activité (BuilderScore) — les freins progressifs −⅓/−⅔/−100 % de la spec §3.3
# restent un raffinement à câbler (compteur_repli déjà prévu en base).
class BuilderMonthlyEngine
  Result = Struct.new(:status, :period, :processed, :lines, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
    y, m = period.split("-").map(&:to_i)
    @at = Time.zone.local(y, m, 1).end_of_month
  end

  def call
    lines = []
    ranked = 0
    Membership.order(:member_id).pluck(:member_id).each do |member_id|
      s = BuilderScore.for(member_id, @at)
      st = BuilderStatus.find_or_initialize_by(member_id: member_id)
      st.rang = s[:rang]
      st.score_foret = s[:sf].round(4)
      st.save!
      ranked += 1 if s[:rang].positive?

      # V5.1 : on retourne le détail de TOUS les membres (transparence) — chaque
      # variable sous-jacente du Score Forêt, pour comprendre le rang (et pourquoi 0).
      lines << { member_id: member_id, sf: s[:sf], rang: s[:rang],
                 rang_nom: PrimeRangMath.nom(s[:rang]), qualified: s[:qualified],
                 gate: BuilderScore::GATE_QUALIFIED, gate_ouvert: s[:qualified] >= BuilderScore::GATE_QUALIFIED,
                 equipe: s[:team], arbre: s[:arbre], racines: s[:racines], activite: s[:activite] }
    end
    Result.new(status: :processed, period: @period, processed: ranked, lines: lines)
  end
end
