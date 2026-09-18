# frozen_string_literal: true

# Adhésion d'un membre au programme de fidélité (indépendante du parrainage).
# L'identité de la personne est gérée par le cœur de système ; ici on ne stocke
# que la référence externe `member_id` et le statut d'adhésion.
#
# V6 (Phase 1) ajoute : e-mail, date du 1er achat (`first_purchase_at`, base de
# l'éligibilité « 15 jours »), blocage anti-fraude, et l'horodatage CGU/CGV.
class Membership < ApplicationRecord
  STATUSES = %w[active suspended closed].freeze

  # V6 — délai minimal entre le 1er achat et le droit d'enrôler (anti-fraude).
  ENROLL_ELIGIBILITY_DAYS = 15

  validates :member_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  before_validation { self.enrolled_at ||= Time.current }

  # V6 — le membre peut-il enrôler un filleul ? Il faut un 1er achat daté et un
  # ancienneté d'achat >= 15 jours, et ne pas être bloqué.
  def enrollment_eligible?(at: Time.current)
    return false if blocked?
    return false if first_purchase_at.blank?

    first_purchase_at <= at - ENROLL_ELIGIBILITY_DAYS.days
  end

  # Nombre de jours restants avant l'éligibilité (0 si déjà éligible).
  def days_until_eligible(at: Time.current)
    return nil if first_purchase_at.blank?

    ready_at = first_purchase_at + ENROLL_ELIGIBILITY_DAYS.days
    return 0 if ready_at <= at

    ((ready_at - at) / 1.day).ceil
  end
end
