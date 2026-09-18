# frozen_string_literal: true

module Api
  module V1
    class PrimeStatutController < ApplicationController
      # POST /v1/prime-statut/run  { period }
      # Batch de la Prime de Statut. Idempotent par état ; message clair (B7).
      def run
        r = PrimeStatutEngine.call(period: params.require(:period))
        case r.status
        when :already_run
          render json: { status: "already_run", period: r.period,
                         message: "Prime de Statut #{r.period} déjà calculée. Rien à refaire." }, status: :ok
        when :empty
          render json: { status: "empty", period: r.period,
                         message: "Aucune poche Prime de Statut pour #{r.period} : aucun achat de cette période " \
                                  "n'a alimenté la poche 5 % (config V5-2026). Fais des achats sur #{r.period}, " \
                                  "puis relance." }, status: :ok
        when :duplicate
          render json: { status: "duplicate", message: "Traitement concurrent identique ignoré." }, status: :ok
        else
          render json: {
            status: "processed", period: r.period, p: r.p.round(4), membres_traites: r.processed,
            poche: fmt(r.poche), distribue: fmt(r.distributed), reserve: fmt(r.reserve_closing),
            message: "Prime de Statut #{r.period} : #{r.processed} membre(s), p=#{r.p.round(3)}, " \
                     "poche #{fmt(r.poche)} → distribué #{fmt(r.distributed)}, réserve #{fmt(r.reserve_closing)}.",
            detail: r.lines.map { |l|
              { member_id: l[:member_id], niveau: l[:niveau], assiette: fmt(l[:assiette]),
                taux: "#{format('%.1f', (0.40 + l[:majoration]) * 100)}%", prime: fmt(l[:prime]) }
            }
          }, status: :created
        end
      end

      # POST /v1/prime-statut/purge  { period } — purge « point barre » (rejeu).
      def purge
        r = PrimeStatutRollback.call(period: params.require(:period))
        if r.status == :nothing_to_purge
          render json: { status: "nothing_to_purge", period: r.period,
                         message: "Rien à purger pour #{r.period} (aucune prime calculée)." }, status: :ok
        else
          render json: { status: "purged", period: r.period, reinitialises_count: r.reset_count,
                         message: "Purge #{r.period} : #{r.reset_count} prime(s) remise(s) à zéro. " \
                                  "La période est vierge, le batch peut être relancé." }, status: :ok
        end
      end

      # GET /v1/prime-statut  -> photos + réserve courante
      def show
        render json: {
          reserve: fmt(PrimeStatutReserve.order(:period).last&.closing || 0),
          rewards: PrimeStatutReward.order(id: :desc).limit(100).map { |r|
            { period: r.period, member_id: r.member_id, display_name: name_of(r.member_id),
              niveau: r.niveau, assiette: fmt(r.assiette),
              taux: "#{format('%.1f', (0.40 + r.majoration_rate) * 100)}%", prime: fmt(r.prime) }
          }
        }
      end

      private

      def name_of(mid) = Membership.find_by(member_id: mid)&.display_name.presence || "##{mid}"
      def fmt(v) = format("%.6f", v)
    end
  end
end
