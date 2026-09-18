# frozen_string_literal: true

# Niveau (1..20) TENU par un membre — rempli par le batch de statut acheteur,
# consommé par le moteur Prime de Statut.
class MemberStatus < ApplicationRecord
  validates :member_id, presence: true, uniqueness: true
  validates :niveau_tenu, inclusion: { in: 1..20 }
  validates :grand_niveau, inclusion: { in: 1..5 }
end
