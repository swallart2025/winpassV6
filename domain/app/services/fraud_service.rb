# frozen_string_literal: true

# V6 — Gestion de la fraude.
# Règle Phase 1 : sur signalement d'un filleul fraudeur, le PARRAIN direct est
# BLOQUÉ le temps de l'enquête (ouverture du dossier). À la clôture :
#   * confirmed : fraude avérée -> le parrain reste bloqué (exclusion possible) ;
#   * cleared   : blanchi -> le blocage est levé (s'il ne reste aucun autre
#     dossier ouvert le concernant).
class FraudService
  OpenResult  = Struct.new(:status, :fraud_case, :sponsor_member_id, keyword_init: true)
  CloseResult = Struct.new(:status, :fraud_case, keyword_init: true)

  # Ouvre un dossier : bloque le parrain direct du filleul signalé.
  def self.open!(reported_member_id:, reason: nil, at: Time.current)
    relation = MemberSponsorship.valid_at(reported_member_id, at)
    return OpenResult.new(status: :no_sponsor) if relation.nil?

    sponsor = relation.sponsor_member_id
    fraud_case = nil
    ActiveRecord::Base.transaction do
      Membership.where(member_id: sponsor).update_all(
        blocked: true, blocked_reason: reason.presence || "enquête fraude", updated_at: at
      )
      fraud_case = FraudCase.create!(
        member_id: sponsor, reported_member_id: reported_member_id,
        status: "open", reason: reason, opened_at: at
      )
    end
    OpenResult.new(status: :opened, fraud_case: fraud_case, sponsor_member_id: sponsor)
  end

  # Fraude avérée : le parrain reste bloqué (exclusion à décider hors moteur).
  def self.confirm!(fraud_case_id:, at: Time.current)
    fc = FraudCase.find_by(id: fraud_case_id)
    return CloseResult.new(status: :not_found) if fc.nil?
    return CloseResult.new(status: :already, fraud_case: fc) if fc.closed?

    fc.update!(status: "confirmed", closed_at: at)
    CloseResult.new(status: :confirmed, fraud_case: fc)
  end

  # Blanchi : on lève le blocage si aucun autre dossier ouvert ne subsiste.
  def self.clear!(fraud_case_id:, at: Time.current)
    fc = FraudCase.find_by(id: fraud_case_id)
    return CloseResult.new(status: :not_found) if fc.nil?
    return CloseResult.new(status: :already, fraud_case: fc) if fc.closed?

    ActiveRecord::Base.transaction do
      fc.update!(status: "cleared", closed_at: at)
      others = FraudCase.open_cases.where(member_id: fc.member_id).exists?
      unless others
        Membership.where(member_id: fc.member_id).update_all(
          blocked: false, blocked_reason: nil, updated_at: at
        )
      end
    end
    CloseResult.new(status: :cleared, fraud_case: fc)
  end
end
