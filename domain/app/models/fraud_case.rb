# frozen_string_literal: true

# V6 — Dossier de fraude. À l'ouverture, le PARRAIN (`member_id`) est bloqué le
# temps de l'enquête ; `reported_member_id` est le filleul à l'origine du signal.
# Résolution : 'confirmed' (fraude avérée, exclusion possible) ou 'cleared'
# (blanchi, le blocage est levé).
class FraudCase < ApplicationRecord
  STATUSES = %w[open confirmed cleared].freeze

  validates :member_id, :opened_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :open_cases, -> { where(status: "open") }

  def closed?
    status != "open"
  end
end
