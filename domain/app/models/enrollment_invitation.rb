# frozen_string_literal: true

# V6 — Invitation d'enrôlement envoyée par un parrain (ou par import de masse).
# Le lien porte un `token` ; la landing recueille l'acceptation CGU/CGV avant de
# créer l'adhésion. `source` distingue l'invitation applicative de l'import.
class EnrollmentInvitation < ApplicationRecord
  STATUSES = %w[sent accepted expired].freeze
  SOURCES  = %w[app mass_import].freeze

  validates :email, :sponsor_member_id, :token, presence: true
  validates :token, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  scope :pending, -> { where(status: "sent") }

  def accepted?
    status == "accepted"
  end

  def cgu_cgv_accepted?
    cgu_accepted_at.present? && cgv_accepted_at.present?
  end
end
