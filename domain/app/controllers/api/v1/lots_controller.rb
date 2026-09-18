# frozen_string_literal: true

module Api
  module V1
    # GET   /v1/lots        -> tous les lots (vue brute wallet_lots)
    # PATCH /v1/lots/:id     { expires_at }  -> modifie la date de fin de validité
    class LotsController < ApplicationController
      def index
        # 500 lots les plus récents (borne le volume sous charge). Affichage : 8 + menu déroulant.
        render json: WalletLot.order(id: :desc).limit(500).map { |l| lot_json(l) }
      end

      def update
        lot = WalletLot.find(params[:id])
        lot.update!(expires_at: params.require(:expires_at))
        render json: lot_json(lot)
      end

      private

      def lot_json(l)
        {
          id: l.id, member_id: l.member_id, display_name: name_of(l.member_id),
          order_id: l.earn&.order_id, merchant_id: l.earn&.merchant_id,
          initial_amount: fmt(l.initial_amount), remaining: fmt(l.remaining),
          earned_at: l.earned_at, expires_at: l.expires_at, status: l.status
        }
      end

      def name_of(mid) = Membership.find_by(member_id: mid)&.display_name.presence || "##{mid}"
      def fmt(v) = format("%.6f", v)
    end
  end
end
