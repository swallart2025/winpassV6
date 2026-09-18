# frozen_string_literal: true

require "securerandom"

# V6 — Enrôlement des membres.
#   * invite!      : un parrain (éligible) invite un e-mail -> jeton + lien landing.
#   * accept!      : la landing recueille l'acceptation CGU/CGV -> crée l'adhésion,
#                    le portefeuille, le compte cashback, le compteur, et rattache
#                    le nouveau membre à son parrain.
#   * import_mass! : création en masse d'invitations à partir d'un fichier à plat.
#
# Les member_id sont ATTRIBUÉS ici pour les nouveaux membres applicatifs (au-dessus
# d'une base réservée pour ne pas heurter les identifiants de démonstration).
class EnrollmentService
  BASE_MEMBER_ID = 10_000 # les nouveaux membres applicatifs commencent au-dessus

  InviteResult = Struct.new(:status, :invitation, :reason, keyword_init: true)
  AcceptResult = Struct.new(:status, :membership, :invitation, :reason, keyword_init: true)

  # -- Invitation par un parrain -------------------------------------------------
  def self.invite!(sponsor_member_id:, email:, source: "app", at: Time.current)
    email = email.to_s.downcase.strip

    if source == "app"
      elig = EnrollmentEligibility.check(member_id: sponsor_member_id, at: at)
      return InviteResult.new(status: :ineligible, reason: elig.reason) unless elig.eligible
    end

    invitation = EnrollmentInvitation.create!(
      email: email, sponsor_member_id: sponsor_member_id,
      token: SecureRandom.urlsafe_base64(24), status: "sent", source: source
    )
    InviteResult.new(status: :sent, invitation: invitation)
  end

  # -- Acceptation sur la landing (CGU/CGV obligatoires) -------------------------
  def self.accept!(token:, display_name:, cgu:, cgv:, at: Time.current)
    invitation = EnrollmentInvitation.find_by(token: token)
    return AcceptResult.new(status: :not_found)                     if invitation.nil?
    return AcceptResult.new(status: :already, invitation: invitation) if invitation.accepted?
    unless truthy(cgu) && truthy(cgv)
      return AcceptResult.new(status: :cgu_cgv_required, invitation: invitation)
    end

    membership = nil
    ActiveRecord::Base.transaction do
      member_id  = next_member_id!
      membership = Membership.create!(
        member_id: member_id, display_name: display_name.presence || invitation.email,
        status: "active", email: invitation.email,
        cgu_accepted_at: at, cgv_accepted_at: at
      )
      Wallet.create!(member_id: member_id)
      CashbackAccount.create!(member_id: member_id)
      MemberPocheCounter.create!(member_id: member_id)
      MemberSponsorship.create!(
        member_id: member_id, sponsor_member_id: invitation.sponsor_member_id,
        effective_from: at, reason: "signup"
      )
      invitation.update!(
        status: "accepted", member_id: member_id, display_name: display_name,
        cgu_accepted_at: at, cgv_accepted_at: at
      )
    end
    AcceptResult.new(status: :accepted, membership: membership, invitation: invitation)
  end

  # -- Import de masse (fichier à plat déjà parsé en lignes) ---------------------
  # rows : [{ email:, sponsor_member_id: }, ...]. Retourne le nombre créé.
  def self.import_mass!(rows:, at: Time.current)
    created = 0
    Array(rows).each do |row|
      email  = (row[:email] || row["email"]).to_s.downcase.strip
      sponsor = (row[:sponsor_member_id] || row["sponsor_member_id"]).to_i
      next if email.blank? || sponsor.zero?

      invite!(sponsor_member_id: sponsor, email: email, source: "mass_import", at: at)
      created += 1
    end
    created
  end

  # ------------------------------------------------------------------------------
  def self.next_member_id!
    top = Membership.maximum(:member_id).to_i
    [top + 1, BASE_MEMBER_ID].max
  end

  def self.truthy(v)
    [true, "true", "1", 1, "on", "yes"].include?(v)
  end
end
