# frozen_string_literal: true

# Batch mensuel du STATUT ACHETEUR. Pour chaque membre : score du mois -> niveau
# mérité -> niveau TENU en appliquant les freins à la baisse (spec §9).
#
#   * Montée : immédiate (niveau ET grand niveau).
#   * Sursis (sur le niveau) : `sursis_avant_baisse` mois de répit avant toute baisse.
#   * Garantie (sur le grand niveau) : on ne descend pas sous son grand niveau avant
#     `garantie_grand_niveau` mois ; à l'échéance, on lâche 1 grand niveau au plus.
#
# Idempotent par état pour une période : on recalcule le niveau tenu de façon
# déterministe à partir de l'état courant + le score ; relancer le même mois après
# des achats supplémentaires met simplement le niveau à jour (montée possible).
class StatusMonthlyEngine
  SURSIS_AVANT_BAISSE     = 3
  GARANTIE_GRAND_NIVEAU   = 6
  GRANDS_NIVEAUX_PAR_GAR  = 1

  Result = Struct.new(:status, :period, :processed, :lines, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
    y, m = period.split("-").map(&:to_i)
    @period_end   = Time.zone.local(y, m, 1).end_of_month
    @period_index = (y * 12) + m
  end

  def call
    lines = []
    Membership.order(:member_id).pluck(:member_id).each do |member_id|
      s = StatusScore.for(member_id, @period)
      merite = [20, (s[:score] / 5) + 1].min
      st = apply_freins!(member_id, merite)
      lines << { member_id: member_id, score: s[:score], niveau_merite: merite,
                 niveau_tenu: st.niveau_tenu, grand_niveau: st.grand_niveau }
    end
    Result.new(status: :processed, period: @period, processed: lines.size, lines: lines)
  end

  private

  def grand_niveau_of(niveau) = ((niveau - 1) / 4) + 1
  def plancher_of(grand)      = ((grand - 1) * 4) + 1

  def apply_freins!(member_id, merite)
    st = MemberStatus.find_or_initialize_by(member_id: member_id)
    if st.new_record?
      st.assign_attributes(niveau_tenu: merite, grand_niveau: grand_niveau_of(merite),
                           compteur_repli: 0, date_entree_gn: @period_end)
      st.save!
      return st
    end

    if merite >= st.niveau_tenu
      new_gn = grand_niveau_of(merite)
      st.date_entree_gn = @period_end if new_gn != st.grand_niveau
      st.niveau_tenu = merite
      st.grand_niveau = new_gn
      st.compteur_repli = 0
    else
      st.compteur_repli += 1
      if st.compteur_repli > SURSIS_AVANT_BAISSE
        plancher = plancher_of(st.grand_niveau)
        months_in_gn = @period_index - gn_index(st.date_entree_gn)
        if months_in_gn >= GARANTIE_GRAND_NIVEAU && merite < plancher
          st.grand_niveau = [1, st.grand_niveau - GRANDS_NIVEAUX_PAR_GAR].max
          st.date_entree_gn = @period_end
          plancher = plancher_of(st.grand_niveau)
        end
        st.niveau_tenu = [merite, plancher].max
        st.grand_niveau = grand_niveau_of(st.niveau_tenu)
      end
    end
    st.save!
    st
  end

  def gn_index(date)
    d = date || @period_end
    (d.year * 12) + d.month
  end
end
