# frozen_string_literal: true

# V6 — Vue « espace parrain » côté membre. Confidentialité stricte :
#   * les FILLEULS DIRECTS (G1) sont nommés (nom + statut) — jamais leur
#     commission ni le détail de leurs achats ;
#   * les NIVEAUX SUIVANTS (G2+) sont ANONYMISÉS : on n'expose que des COMPTES
#     par génération, jamais d'identité ni de montant individuel ;
#   * on n'affiche JAMAIS la commission d'apport : seuls le cashback du membre
#     (en attente / Crédit Winpass) et le compteur « parrainage reçu » sont
#     restitués, en euros.
class ParrainView
  MAX_DEPTH = 7

  def self.build(member_id:, at: Time.current)
    new(member_id, at).build
  end

  def initialize(member_id, at)
    @member_id = member_id.to_i
    @at = at
  end

  def build
    {
      member_id: @member_id,
      eligible_to_enroll: EnrollmentEligibility.check(member_id: @member_id, at: @at).eligible,
      direct: direct_filleuls,
      deeper: deeper_counts,
      cashback: cashback_block,
      autres_poches: autres_poches_block
    }
  end

  private

  # G1 : filleuls directs, nommés (nom + statut), sans aucun montant.
  def direct_filleuls
    children_of(@member_id).map do |child_id|
      m = Membership.find_by(member_id: child_id)
      { member_id: child_id, display_name: m&.display_name || "Membre ##{child_id}",
        active: m&.status == "active" }
    end
  end

  # G2..G7 : uniquement des COMPTES par génération (anonymisé).
  def deeper_counts
    by_gen = {}
    frontier = children_of(@member_id)
    generation = 1
    while generation < MAX_DEPTH && frontier.any?
      generation += 1
      frontier = frontier.flat_map { |id| children_of(id) }
      by_gen[generation] = frontier.size if frontier.any?
    end
    { total: by_gen.values.sum, by_generation: by_gen }
  end

  def cashback_block
    acct = CashbackAccount.find_by(member_id: @member_id)
    {
      pending:  fmt(acct&.pending_amount),
      credit_winpass: fmt(acct&.credit_winpass_amount),
      lifetime: fmt(acct&.lifetime_cashback)
    }
  end

  def autres_poches_block
    c = MemberPocheCounter.find_by(member_id: @member_id)
    {
      parrainage_recu: fmt(c&.parrainage_recu),
      prime_statut:    fmt(c&.prime_statut),
      comportemental:  fmt(c&.comportemental),
      grands_leaders:  fmt(c&.grands_leaders),
      fonctionnement:  fmt(c&.fonctionnement),
      total_autres:    fmt(c&.total_autres || 0)
    }
  end

  def children_of(sponsor_id)
    MemberSponsorship.active.where(sponsor_member_id: sponsor_id).pluck(:member_id)
  end

  def fmt(v)
    format("%.2f", (v || 0).to_f)
  end
end
