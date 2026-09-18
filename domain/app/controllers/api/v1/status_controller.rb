# frozen_string_literal: true

module Api
  module V1
    class StatusController < ApplicationController
      # POST /v1/status/run  { period }  — batch mensuel du statut acheteur.
      def run
        r = StatusMonthlyEngine.call(period: params.require(:period))
        render json: {
          status: "processed", period: r.period, membres_traites: r.processed,
          message: "Statuts #{r.period} : #{r.processed} membre(s) recalculé(s).",
          detail: r.lines.map { |l|
            { member_id: l[:member_id], score: l[:score], niveau_merite: l[:niveau_merite],
              niveau_tenu: l[:niveau_tenu], grand_niveau: l[:grand_niveau] }
          }
        }, status: :created
      end

      # GET /v1/status  — niveaux tenus courants.
      def show
        render json: MemberStatus.order(:member_id).map { |s|
          { member_id: s.member_id, display_name: name_of(s.member_id),
            niveau_tenu: s.niveau_tenu, grand_niveau: s.grand_niveau,
            compteur_repli: s.compteur_repli }
        }
      end

      private

      def name_of(mid) = Membership.find_by(member_id: mid)&.display_name.presence || "##{mid}"
    end
  end
end
