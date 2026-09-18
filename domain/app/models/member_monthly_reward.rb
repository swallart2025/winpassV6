# frozen_string_literal: true

# Photo mensuelle immuable de la récompense comportementale d'un membre :
# potentiel du mois, score d'adhésion, taux débloqué, récompense versée et
# contribution à la CIC. Une seule par (membre, période).
class MemberMonthlyReward < ApplicationRecord
  include Immutable
  belongs_to :reward_config, optional: true

  validates :member_id, :period, presence: true
  validates :period, uniqueness: { scope: :member_id }
end
