# frozen_string_literal: true

module Api
  module V1
    class MembersController < ApplicationController
      # GET /v1/members
      # État complet du réseau pour le tableau de bord : chaque membre avec son
      # solde, son rôle, son parrain, TOUTES ses transactions et sa remontée de
      # gains nette. Tout est lu depuis PostgreSQL (aucune donnée simulée).
      def index
        members     = Membership.order(:member_id).to_a
        names       = members.each_with_object({}) { |m, h| h[m.member_id] = display_name(m) }
        active      = MemberSponsorship.active.pluck(:member_id, :sponsor_member_id).to_h
        sponsors    = active.values.map(&:to_i).to_set
        wallets     = Wallet.where(member_id: members.map(&:member_id)).index_by(&:member_id)
        statements  = WalletStatement.where(member_id: members.map(&:member_id)).chronological
                                     .group_by(&:member_id)

        @rate_map  = build_rate_map(members.map(&:member_id))
        @campaigns = Campaign.active.to_a
        @scorer    = BehavioralScore.new if @campaigns.any?

        render json: members.map { |m|
          member_payload(m, wallets[m.member_id], active, sponsors, names, statements[m.member_id] || [])
        }
      end

      # GET /v1/members/:id
      def show
        m = Membership.find_by!(member_id: params[:id])
        active   = MemberSponsorship.active.pluck(:member_id, :sponsor_member_id).to_h
        sponsors = active.values.map(&:to_i).to_set
        names    = { m.member_id => display_name(m) }
        stmts    = WalletStatement.where(member_id: m.member_id).chronological.to_a
        @rate_map = build_rate_map([m.member_id])
        render json: member_payload(m, Wallet.find_by(member_id: m.member_id), active, sponsors, names, stmts)
      end

      private

      # Taux appliqué par (membre, commande, génération), lu en UNE requête sur
      # earn_ledgers (bug #5 : le relevé ne le stocke pas). Sert à afficher le taux
      # sur chaque ligne d'earn / d'annulation d'earn, sans requête par ligne (N+1).
      def build_rate_map(member_ids)
        EarnLedger.where(member_id: member_ids).where.not(applied_rate: nil)
                  .pluck(:member_id, :order_id, :generation, :applied_rate)
                  .each_with_object({}) { |(mid, oid, gen, rate), h| h[[mid, oid, gen.to_i]] = rate }
      end

      # Nombre de transactions renvoyées par membre (borne le volume sous charge).
      # Le tableau de bord n'en montre que 8, le reste en menu déroulant.
      TX_LIMIT = 200

      def member_payload(membership, wallet, active, sponsors, names, statements)
        mid          = membership.member_id
        sponsor_id   = active[mid]
        # Les agrégats (remontée nette) restent calculés sur TOUT l'historique ;
        # seule la LISTE affichée est bornée aux plus récentes.
        net_spon     = statements.select(&:sponsorship_related?).sum(&:amount)
        recent       = statements.last(TX_LIMIT)
        {
          member_id: mid,
          display_name: names[mid] || "##{mid}",
          status: membership.status,
          role: role_for(mid, sponsors, active),
          sponsor_member_id: sponsor_id,
          sponsor_name: sponsor_id && (names[sponsor_id] || "##{sponsor_id}"),
          balance: fmt(wallet&.available_balance || 0),
          net_sponsorship_gain: fmt(net_spon),
          campaign_offers: campaign_offers_for(mid),
          transactions_total: statements.size,
          transactions: recent.map { |s| tx_payload(s, names) }
        }
      end

      def tx_payload(s, names)
        rate = @rate_map && @rate_map[[s.member_id, s.order_id, (s.generation || 0)]]
        {
          kind: s.kind, label: s.label, generation: s.generation, order_id: s.order_id,
          merchant_id: s.merchant_id,
          counterparty_member_id: s.counterparty_member_id,
          counterparty_name: s.counterparty_member_id && (names[s.counterparty_member_id] || fetch_name(s.counterparty_member_id)),
          applied_rate: rate&.to_s,
          amount: fmt(s.amount), balance_after: fmt(s.balance_after),
          created_at: s.created_at
        }
      end

      # Campagnes actives pour lesquelles le membre est éligible (score catégorie ≤ seuil).
      def campaign_offers_for(mid)
        return [] if @campaigns.blank?

        @campaigns.select { |c| @scorer.score_in_category(mid, c.category, Time.current) <= c.eligibility_score_max }
                  .map { |c| { campaign_id: c.id, category: c.category, reward_type: c.reward_type, reward_value: fmt(c.reward_value) } }
      end

      def role_for(mid, sponsors, active)
        is_sponsor = sponsors.include?(mid)
        is_filleul = active.key?(mid)
        return "both"    if is_sponsor && is_filleul
        return "parrain" if is_sponsor
        return "filleul" if is_filleul

        "membre"
      end

      def display_name(membership)
        membership.display_name.presence || "##{membership.member_id}"
      end

      def fetch_name(member_id)
        @name_cache ||= {}
        @name_cache[member_id] ||= (Membership.find_by(member_id: member_id)&.display_name.presence || "##{member_id}")
      end

      def fmt(value)
        format("%.6f", value)
      end
    end
  end
end
