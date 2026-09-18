# frozen_string_literal: true

# Lot d'unités issu d'un Earn (projection FEFO). `remaining` est borné entre 0
# et `initial_amount` par des contraintes de base. Le lien 1:1 avec l'Earn est
# garanti par un index unique sur earn_id.
class WalletLot < ApplicationRecord
  belongs_to :earn, class_name: "EarnLedger", inverse_of: :wallet_lot

  validates :member_id, :earned_at, :expires_at, presence: true
  validates :initial_amount, numericality: { greater_than: 0 }
  validates :remaining,
            numericality: { greater_than_or_equal_to: 0 }
  validate  :remaining_within_initial

  # Statuts possibles d'un lot :
  #   active   : disponible, consommable en FEFO ;
  #   consumed : vidé par des paiements en points ;
  #   expired  : sorti par le batch d'expiration (validité dépassée) ;
  #   reversed : neutralisé par une ANNULATION de la commande d'origine — la ligne
  #              est conservée pour l'audit mais n'est plus consommable (bug #1).
  #   pending  : solde EN ATTENTE de confirmation (délai de rétractation) — non
  #              consommable tant que `available_from` n'est pas atteint (V5).
  STATUSES = %w[active consumed expired reversed pending].freeze
  validates :status, inclusion: { in: STATUSES }

  scope :active,   -> { where(status: "active") }
  scope :expired,  -> { where(status: "expired") }
  scope :consumed, -> { where(status: "consumed") }
  scope :reversed, -> { where(status: "reversed") }
  scope :pending,  -> { where(status: "pending") }

  # Lots en attente dont le délai est écoulé -> à activer.
  scope :pending_due, ->(now) { where(status: "pending").where("available_from <= ?", now) }

  # Sélection FEFO sous verrou : lots ACTIFS disponibles, du plus tôt expiré au plus tard.
  scope :fefo_for_update, lambda { |member_id|
    where(member_id: member_id, status: "active").where("remaining > 0")
      .order(:expires_at, :earned_at, :id).lock("FOR UPDATE")
  }

  # Passe le lot à "consommé" quand il est vidé (appelé après un débit FEFO).
  def mark_consumed_if_empty!
    update!(status: "consumed") if remaining <= 0 && status == "active"
  end

  private

  def remaining_within_initial
    return if remaining.nil? || initial_amount.nil?

    errors.add(:remaining, "ne peut pas dépasser le montant initial") if remaining > initial_amount
  end
end
