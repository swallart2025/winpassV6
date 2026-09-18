# frozen_string_literal: true

module Api
  module V1
    class BehavioralController < ApplicationController
      # POST /v1/behavioral/run  { period, as_of? }
      # B5 : idempotent PAR ÉTAT (présence des photos mensuelles), pas par une clé
      # horodatée. Relancer un mois déjà exécuté = no-op signalé (`already_run`).
      # B7 : renvoie toujours un `message` clair pour l'affichage.
      def run
        result = BehavioralMonthlyEngine.call(period: params.require(:period), as_of: params[:as_of])
        case result.status
        when :already_run
          render json: { status: "already_run", period: result.period,
                         message: "Le batch #{result.period} a déjà été exécuté. Purgez-le d'abord pour le rejouer." },
                 status: :ok
        when :duplicate
          render json: { status: "duplicate", message: "Traitement concurrent identique ignoré." }, status: :ok
        else
          render json: {
            status: "processed", period: result.period, membres_traites: result.processed,
            cic_apres: fmt(result.cic_after),
            message: "Batch #{result.period} : #{result.processed} membre(s) traité(s), CIC = #{fmt(result.cic_after)} €.",
            detail: result.lines.map { |l|
              { member_id: l[:member_id], potentiel: fmt(l[:potential]), score: l[:score],
                taux: "#{l[:unlocked_rate]}%", recompense: fmt(l[:reward]), vers_cic: fmt(l[:cic_contribution]) }
            }
          }, status: :created
        end
      end

      # POST /v1/behavioral/purge  { period }
      # PURGE « point barre » (V5.1) : remet la période à zéro pour la rejouer. Elle
      # ne rejoue rien. Idempotent par état (rien à purger si aucun batch).
      def purge
        result = BehavioralRollback.call(period: params.require(:period))
        case result.status
        when :nothing_to_purge
          render json: { status: "nothing_to_purge", period: result.period,
                         message: "Rien à purger pour #{result.period} (aucun batch exécuté)." }, status: :ok
        else
          render json: {
            status: "purged", period: result.period,
            reinitialises: result.rolled_back, reinitialises_count: result.rolled_back.size,
            cic_apres: fmt(result.cic_after),
            message: "Purge #{result.period} : #{result.rolled_back.size} récompense(s) remise(s) à zéro. " \
                     "Le mois est vierge, le batch peut être relancé. CIC = #{fmt(result.cic_after)} €."
          }, status: :ok
        end
      end

      # GET /v1/behavioral  -> CIC, cagnottes, campagnes, photos mensuelles
      def show
        render json: {
          cic_balance: fmt(CicLedger.balance),
          pools: pools_json,
          campaigns: Campaign.order(id: :desc).map { |c| campaign_json(c) },
          monthly_reports: MemberMonthlyReward.order(id: :desc).limit(50).map { |r|
            { period: r.period, member_id: r.member_id, display_name: name_of(r.member_id),
              potentiel: fmt(r.potential), score: r.score, taux: "#{r.unlocked_rate}%",
              recompense: fmt(r.reward), vers_cic: fmt(r.cic_contribution) }
          }
        }
      end

      # GET /v1/behavioral/score?member_id=&as_of=
      # Détail du score d'adhésion par catégorie à une date donnée (bug #9), et
      # support de l'ÉMULATION temporelle : en faisant varier `as_of`, on visualise
      # la décroissance mois après mois, puis le rechargement après un achat antidaté.
      def score
        member_id = params.require(:member_id).to_i
        scorer = BehavioralScore.new
        now = Time.current

        # B9 — le back est AUTORITAIRE : il renvoie toujours le score du jour.
        score_now = scorer.score(member_id, now)

        # B3 — une « date de calcul » est traitée comme la JOURNÉE ENTIÈRE (fin de
        # journée) : sinon un achat du jour même (horodaté à 10h, 14h…) serait exclu
        # par le filtre `delivered_at <= at` (qui valait minuit).
        at = params[:as_of].present? ? Time.zone.parse(params[:as_of]).end_of_day : now
        is_emulation = params[:as_of].present? && at.to_date != now.to_date
        score_at = scorer.score(member_id, at)

        lines = scorer.categories.map do |cat|
          meta = scorer.meta_for(cat)
          st   = scorer.category_contribution(member_id, cat, at)
          { category: cat, max: meta[:max], validity_months: meta[:validity_months],
            qualifying_min: meta[:qualifying_min].to_s,
            cumulative: fmt(st[:cumulative]), contribution: fmt(st[:contribution]),
            last_recharge_at: st[:last_recharge_at] }
        end
        render json: { member_id: member_id, display_name: name_of(member_id),
                       score_now: score_now, score_at: score_at, as_of: at,
                       is_emulation: is_emulation, score: score_at, categories: lines }
      end

      private

      # Soldes cumulés des cagnottes centrales + CIC (bug #4).
      def pools_json
        by_type = PoolContribution.group(:pool_type).sum(:amount)
        {
          fonctionnement: fmt(by_type["fonctionnement"] || 0),
          grands_leaders: fmt(by_type["grands_leaders"] || 0),
          comportemental: fmt(by_type["comportemental"] || 0),
          prime_statut: fmt(by_type["prime_statut"] || 0),
          cic: fmt(CicLedger.balance),
          campagnes_reservees: fmt(Campaign.active.sum { |c| c.remaining_budget })
        }
      end

      def campaign_json(c)
        { id: c.id, category: c.category, eligibility_score_max: c.eligibility_score_max,
          reward_type: c.reward_type, reward_value: fmt(c.reward_value),
          budget_reserved: fmt(c.budget_reserved), budget_spent: fmt(c.budget_spent),
          end_date: c.end_date, status: c.status }
      end

      def name_of(mid) = Membership.find_by(member_id: mid)&.display_name.presence || "##{mid}"
      def fmt(v) = format("%.6f", v)
    end
  end
end
