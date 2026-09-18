# frozen_string_literal: true

# Construit la chaîne ascendante des parrains RÉMUNÉRÉS pour un achat, à une date
# donnée, en appliquant la compression verticale :
#   - on part de l'acheteur et on remonte les relations valables à `delivered_at` ;
#   - un parrain INACTIF (aucun Earn Personnel depuis `inactivity_months`) est
#     SAUTÉ (retiré de la rémunération) mais reste dans l'arbre ;
#   - on remonte aussi loin que nécessaire pour réunir jusqu'à `max_generation`
#     parrains ACTIFS.
class SponsorshipTree
  Link = Struct.new(:sponsor_member_id, :member_sponsorship_id)

  def initialize(reward_config)
    @max_generation   = reward_config.sponsorship_max_generation
    @inactivity_months = reward_config.inactivity_months
  end

  # @return [Array<Link>] parrains actifs, du plus proche (G1) au plus lointain.
  def active_upline(buyer_member_id, delivered_at)
    chain = []
    current = buyer_member_id
    visited = 0

    while chain.size < @max_generation && visited < 1000
      visited += 1
      relation = MemberSponsorship.valid_at(current, delivered_at)
      break if relation.nil?

      sponsor = relation.sponsor_member_id
      chain << Link.new(sponsor, relation.id) if active?(sponsor, delivered_at)
      current = sponsor
    end

    chain
  end

  private

  # Actif = adhésion au statut "active". C'est ce statut qui pilote la
  # compression verticale (et qui est exposé/contrôlable dans le tableau de bord).
  #
  # NB : la règle métier "inactif = aucun achat personnel depuis N mois" reste
  # prévue (champ `inactivity_months` conservé en configuration). Elle se
  # brancherait ici en ajoutant une condition sur les EarnLedger personnels
  # récents ; on la laisse volontairement en réserve pour garder une démonstration
  # pilotable au statut. Signature inchangée (`at`) pour ce futur branchement.
  def active?(member_id, _at)
    Membership.where(member_id: member_id, status: "active").exists?
  end
end
