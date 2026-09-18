# frozen_string_literal: true

module Api
  module V1
    # POST /v1/campaigns  { category, eligibility_score_max, reward_type, reward_value, budget_reserved, end_date }
    # GET  /v1/campaigns
    class CampaignsController < ApplicationController
      def index
        render json: Campaign.order(id: :desc).map { |c|
          { id: c.id, category: c.category, eligibility_score_max: c.eligibility_score_max,
            reward_type: c.reward_type, reward_value: fmt(c.reward_value),
            budget_reserved: fmt(c.budget_reserved), budget_spent: fmt(c.budget_spent),
            end_date: c.end_date, status: c.status }
        }
      end

      def create
        p = params.permit(:category, :eligibility_score_max, :reward_type, :reward_value, :budget_reserved, :end_date)
        budget = BigDecimal(p[:budget_reserved].to_s)

        campaign = nil
        eligibles = []
        abondement = BigDecimal(0)
        ActiveRecord::Base.transaction do
          # Budget supérieur aux fonds CIC -> on ABONDE automatiquement le manque
          # (banc d'essai) au lieu de refuser la campagne. La CIC reste ainsi >= 0
          # après la réserve, et l'abondement est journalisé (kind manual_credit).
          shortfall = budget - CicLedger.balance
          if shortfall.positive?
            abondement = shortfall
            CicLedger.move!(kind: "manual_credit", amount: shortfall,
                            reference: { source: "abondement auto pour campagne" })
          end

          campaign = Campaign.create!(
            category: p[:category], eligibility_score_max: p[:eligibility_score_max].to_i,
            reward_type: p[:reward_type], reward_value: BigDecimal(p[:reward_value].to_s),
            budget_reserved: budget, end_date: p[:end_date].presence, status: "active"
          )
          CicLedger.move!(kind: "campaign_reserve", amount: -budget, reference: { campaign_id: campaign.id })
          scorer = BehavioralScore.new
          Membership.pluck(:member_id).each do |mid|
            s = scorer.score_in_category(mid, campaign.category, Time.current)
            eligibles << { member_id: mid, score_categorie: s } if s <= campaign.eligibility_score_max
          end
        end
        render json: { campaign_id: campaign.id, status: "active",
                       cic_abondee: (abondement.positive? ? fmt(abondement) : nil),
                       cic_apres: fmt(CicLedger.balance), membres_eligibles: eligibles }, status: :created
      end

      private

      def fmt(v) = format("%.6f", v)
    end
  end
end
