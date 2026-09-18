# frozen_string_literal: true

module Api
  module V1
    class BuildersController < ApplicationController
      # POST /v1/builders/run  { period }  — batch mensuel du rang (Score Forêt).
      # V5.1 : renvoie le DÉTAIL de chaque variable du Score Forêt pour tous les
      # membres (Équipe, Arbre secondaire, Racines, Activité, SF, filleuls qualifiés,
      # gate) — tableau transparent.
      def run
        r = BuilderMonthlyEngine.call(period: params.require(:period))
        gate = BuilderScore::GATE_QUALIFIED
        render json: {
          status: "processed", period: r.period, batisseurs_ranges: r.processed,
          gate_filleuls: gate,
          message: r.processed.positive? ?
            "Rangs Bâtisseurs #{r.period} : #{r.processed} Bâtisseur(s) rangé(s)." :
            "Rangs Bâtisseurs #{r.period} : personne n'est rangé — il faut ≥ #{gate} filleuls directs " \
            "qualifiés (niveau acheteur ≥ 5) pour ouvrir un rang.",
          detail: r.lines.map { |l|
            { member_id: l[:member_id], display_name: name_of(l[:member_id]),
              filleuls_qualifies: l[:qualified], gate_ouvert: l[:gate_ouvert],
              equipe: format("%.3f", l[:equipe]), arbre_secondaire: format("%.3f", l[:arbre]),
              racines: format("%.3f", l[:racines]), activite: format("%.2f", l[:activite]),
              score_foret: format("%.3f", l[:sf]), rang: l[:rang], rang_nom: l[:rang_nom] }
          }
        }, status: :created
      end

      # POST /v1/builders/primes/run  { period: 'YYYY-Qn' } — distribution trimestrielle.
      def primes
        r = BuilderPrimeEngine.call(period: params.require(:period))
        case r.status
        when :already_run
          render json: { status: "already_run", period: r.period,
                         message: "Primes de rang #{r.period} déjà distribuées. Purge d'abord pour rejouer." }, status: :ok
        when :duplicate
          render json: { status: "duplicate", message: "Traitement concurrent identique ignoré." }, status: :ok
        else
          msg = if r.processed.positive?
                  "Primes de rang #{r.period} : #{r.processed} leader(s), poche #{fmt(r.pocket)} → " \
                    "distribué #{fmt(r.distributed)}, RFA cumulée #{fmt(r.rfa)}."
                else
                  "Primes de rang #{r.period} : aucun leader rangé → 0 distribué, toute la poche #{fmt(r.pocket)} " \
                    "part en RFA (#{fmt(r.rfa)}). (Un seul comptage : recliquer ne rajoute plus rien.)"
                end
          render json: {
            status: "processed", period: r.period, benefices: r.processed,
            poche: fmt(r.pocket), distribue: fmt(r.distributed), rfa: fmt(r.rfa), message: msg,
            detail: r.lines.map { |l|
              { member_id: l[:member_id], display_name: name_of(l[:member_id]), rang: l[:rang],
                rang_nom: l[:rang_nom], assiette: fmt(l[:assiette]), prime: fmt(l[:prime]) }
            }
          }, status: :created
        end
      end

      # POST /v1/builders/primes/purge  { period: 'YYYY-Qn' } — purge « point barre ».
      def purge_primes
        r = BuilderPrimeRollback.call(period: params.require(:period))
        if r.status == :nothing_to_purge
          render json: { status: "nothing_to_purge", period: r.period,
                         message: "Rien à purger pour #{r.period} (aucune distribution)." }, status: :ok
        else
          render json: { status: "purged", period: r.period, reinitialises_count: r.reset_count,
                         rfa: fmt(r.rfa),
                         message: "Purge #{r.period} : #{r.reset_count} prime(s) remise(s) à zéro, poche du " \
                                  "trimestre retirée du pot RFA (RFA = #{fmt(r.rfa)}). Rejouable." }, status: :ok
        end
      end

      # GET /v1/builders  — rangs tenus + pot RFA courant.
      def show
        render json: {
          reserve: BuilderReserve.order(:year).last&.then { |r| { year: r.year, pocket: fmt(r.pocket_total),
                                                                  distribue: fmt(r.distributed_total), rfa: fmt(r.rfa_total) } },
          statuses: BuilderStatus.where("rang > 0").order(rang: :desc, member_id: :asc).map { |s|
            { member_id: s.member_id, display_name: name_of(s.member_id), rang: s.rang,
              rang_nom: PrimeRangMath.nom(s.rang), score_foret: fmt(s.score_foret) }
          }
        }
      end

      private

      def name_of(mid) = Membership.find_by(member_id: mid)&.display_name.presence || "##{mid}"
      def fmt(v) = format("%.6f", v)
    end
  end
end
