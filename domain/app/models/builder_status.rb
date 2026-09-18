# frozen_string_literal: true

# Rang Bâtisseur (0..6 = Graine..Canopée) et Score Forêt tenu d'un parrain.
class BuilderStatus < ApplicationRecord
  validates :member_id, presence: true, uniqueness: true
  validates :rang, inclusion: { in: 0..6 }
end
