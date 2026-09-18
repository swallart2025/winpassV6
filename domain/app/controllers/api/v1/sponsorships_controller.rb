# frozen_string_literal: true

module Api
  module V1
    # PUT /v1/sponsorships  { relations: [ { member_id, sponsor_member_id, active } ] }
    # Établit le réseau de parrainage "en amont". Historisé : un changement clôture
    # la relation active (effective_to) et en ouvre une nouvelle — l'arbre passé
    # reste reconstituable.
    class SponsorshipsController < ApplicationController
      def update
        relations = params.permit(relations: %i[member_id sponsor_member_id reason active])[:relations] || []
        applied = []

        ActiveRecord::Base.transaction do
          at = Time.current
          relations.each do |rel|
            member_id = rel[:member_id].to_i
            ensure_member!(member_id)

            active = rel[:active].nil? ? true : ActiveModel::Type::Boolean.new.cast(rel[:active])
            Membership.where(member_id: member_id)
                      .update_all(status: active ? "active" : "suspended", updated_at: at)

            sponsor = rel[:sponsor_member_id].present? ? rel[:sponsor_member_id].to_i : nil
            current = MemberSponsorship.active.find_by(member_id: member_id)

            if sponsor.nil?
              current&.update_columns(effective_to: at) # clôture (transition d'état contrôlée)
            elsif current.nil?
              open_relation!(member_id, sponsor, at)
            elsif current.sponsor_member_id != sponsor
              current.update_columns(effective_to: at)
              open_relation!(member_id, sponsor, at)
            end

            applied << { member_id: member_id, sponsor_member_id: sponsor, active: active }
          end
        end

        render json: { status: "applied", applied: applied.size, relations: applied }, status: :ok
      end

      private

      def open_relation!(member_id, sponsor, at)
        MemberSponsorship.create!(member_id: member_id, sponsor_member_id: sponsor,
                                  effective_from: at, reason: "user_request")
      end

      def ensure_member!(member_id)
        Membership.find_or_create_by!(member_id: member_id)
        Wallet.find_or_create_by!(member_id: member_id)
      rescue ActiveRecord::RecordNotUnique
        retry
      end
    end
  end
end
