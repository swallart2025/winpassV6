# frozen_string_literal: true

# Relation de parrainage historisée : jamais modifiée, jamais supprimée.
# Un changement de parrain clôture la relation active (effective_to) et en crée
# une nouvelle. On peut ainsi reconstituer l'arbre valable à n'importe quelle date.
class MemberSponsorship < ApplicationRecord
  include Immutable

  REASONS = %w[signup migration user_request admin].freeze

  validates :member_id, :sponsor_member_id, :effective_from, presence: true
  validates :reason, inclusion: { in: REASONS }
  validate  :not_self_sponsor

  scope :active, -> { where(effective_to: nil) }

  # Relation valable pour `member_id` à la date `at` (arbre historique).
  def self.valid_at(member_id, at)
    where(member_id: member_id)
      .where("effective_from <= ?", at)
      .where("effective_to IS NULL OR effective_to > ?", at)
      .order(effective_from: :desc)
      .first
  end

  private

  def not_self_sponsor
    errors.add(:sponsor_member_id, "ne peut pas être le membre lui-même") if member_id == sponsor_member_id
  end
end
