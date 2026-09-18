# frozen_string_literal: true

# Bonus de campagne attribué en temps réel à un membre lors d'un achat éligible.
class CampaignReward < ApplicationRecord
  belongs_to :campaign
  validates :member_id, presence: true
  validates :amount, numericality: { greater_than: 0 }
end
