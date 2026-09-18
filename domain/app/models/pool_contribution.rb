# frozen_string_literal: true

# Contribution à une réserve centrale (Fonctionnement, Grands leaders,
# Comportemental). Journal immuable. Les cagnottes non encore affectées sont
# ainsi consultables et auditables.
class PoolContribution < ApplicationRecord
  include Immutable

  POOL_TYPES = %w[fonctionnement grands_leaders comportemental prime_statut].freeze

  validates :pool_type, inclusion: { in: POOL_TYPES }
  # V5 (B2) : montants SIGNÉS — une annulation crée des contributions NÉGATIVES
  # compensatoires (immuabilité préservée : on ajoute, on ne modifie jamais).
  validates :amount, numericality: { other_than: 0 }
  # V5 (B4) : date métier (date d'achat), distincte de created_at (date d'insertion).
  validates :occurred_at, presence: true
end
