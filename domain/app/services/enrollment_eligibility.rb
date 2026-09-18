# frozen_string_literal: true

# V6 — Éligibilité d'un membre à ENRÔLER un filleul.
# Règle anti-fraude Phase 1 : un filleul ne peut parrainer qu'après avoir été un
# membre ACTIF pendant au moins 15 jours d'achat (date du 1er achat + 15 j), et
# à condition de ne pas être bloqué (dossier de fraude en cours).
class EnrollmentEligibility
  Result = Struct.new(:eligible, :reason, :days_remaining, keyword_init: true)

  def self.check(member_id:, at: Time.current)
    membership = Membership.find_by(member_id: member_id)
    return Result.new(eligible: false, reason: "unknown_member") if membership.nil?
    return Result.new(eligible: false, reason: "blocked")        if membership.blocked?
    return Result.new(eligible: false, reason: "no_purchase")    if membership.first_purchase_at.blank?

    if membership.enrollment_eligible?(at: at)
      Result.new(eligible: true, reason: "ok", days_remaining: 0)
    else
      Result.new(eligible: false, reason: "too_recent",
                 days_remaining: membership.days_until_eligible(at: at))
    end
  end
end
