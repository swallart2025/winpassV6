# frozen_string_literal: true

module Api
  module V1
    # GET /v1/orders
    # Vue lisible des COMMANDES (bug #8), reconstituée depuis les journaux :
    # n° de commande, acheteur, enseigne, montant, date, earn total distribué
    # (personnel + parrainage), burn (points dépensés) et statut d'annulation.
    # Aucune table dédiée : la commande est une projection des earn_ledgers /
    # payments / reversals (source unique de vérité, immuable).
    class OrdersController < ApplicationController
      def index
        earns    = EarnLedger.where.not(order_id: nil).order(:order_id, :id).to_a
        payments = Payment.where.not(order_id: nil).group_by(&:order_id)
        reversed = Reversal.pluck(:order_id).to_set
        names    = Membership.pluck(:member_id, :display_name).to_h

        rows = earns.group_by(&:order_id).map do |order_id, lines|
          personal = lines.find { |e| e.earn_type == "personal" } || lines.first
          buyer    = personal&.member_id
          pays     = payments[order_id] || []
          burn     = pays.sum(&:amount)
          {
            order_id: order_id,
            buyer_id: buyer,
            buyer_name: buyer && (names[buyer].presence || "##{buyer}"),
            merchant_id: personal&.merchant_id,
            order_amount: fmt(personal&.order_amount || 0),
            delivered_at: personal&.delivered_at,
            earn_total: fmt(lines.sum(&:amount)),
            beneficiaries: lines.size,
            burn: fmt(burn),
            reversed: reversed.include?(order_id)
          }
        end

        # Plafonné aux 500 commandes les plus récentes (borne le volume sous charge ;
        # le tableau de bord n'en montre que 8, le reste en menu déroulant).
        render json: rows.sort_by { |r| -r[:order_id].to_i }.first(500)
      end

      private

      def fmt(v) = format("%.6f", v)
    end
  end
end
