# frozen_string_literal: true

module Api
  module V1
    # V6 — Cashback (deux soldes) côté membre + conversions.
    #   GET  /v1/cashback?member_id=     -> soldes en attente / Crédit Winpass
    #   POST /v1/cashback/convert        -> conversion manuelle du membre
    #   POST /v1/cashback/cadence/run    -> batch de conversion sur cadence (hebdo)
    class CashbackController < ApplicationController
      def show
        member_id = params.require(:member_id)
        acct = CashbackAccount.find_by(member_id: member_id)
        cfg  = CashbackConfig.current!
        render json: {
          member_id: member_id.to_i,
          pending_amount:        fmt(acct&.pending_amount),
          credit_winpass_amount: fmt(acct&.credit_winpass_amount),
          lifetime_cashback:     fmt(acct&.lifetime_cashback),
          last_conversion_at:    acct&.last_conversion_at,
          config: { threshold_eur: fmt(cfg.threshold_amount), cadence_days: cfg.cadence_days }
        }, status: :ok
      end

      def convert
        member_id = params.require(:member_id)
        r = ConversionEngine.convert_now!(member_id: member_id)
        render json: { status: r.status, converted: r.converted, amount: fmt(r.amount) }, status: :ok
      end

      def run_cadence
        r = ConversionEngine.run_cadence!
        render json: { status: r.status, converted: r.converted, amount: fmt(r.amount) }, status: :ok
      end

      private

      def fmt(v)
        format("%.6f", (v || 0))
      end
    end
  end
end
