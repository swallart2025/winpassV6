# frozen_string_literal: true

require "bigdecimal"

# Batch d'expiration : expire tous les lots ACTIFS dont la date de fin de
# validité est <= à la date de traitement. Le `remaining` tombe à 0, le lot passe
# « expired », le solde du membre est réduit d'autant et le relevé enregistre un
# mouvement `expiration`. Idempotent, atomique, verrouillé.
class ExpirationEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :as_of, :expired_count, :units_removed, :lines, keyword_init: true)

  def self.call(as_of:, event_key:)
    new(as_of, event_key).call
  end

  def initialize(as_of, event_key)
    @as_of = if as_of.is_a?(String) && as_of.present? then Time.zone.parse(as_of)
             elsif as_of.present? then as_of
             else Time.current
             end
    @event_key = event_key
  end

  def call
    ActiveRecord::Base.transaction do
      claim_idempotency_key!
      removed = BigDecimal(0)
      lines = []
      WalletLot.active.where("remaining > 0 AND expires_at <= ?", @as_of)
               .lock.order(:member_id, :id).each do |lot|
        amount = lot.remaining
        apply_movement!(member_id: lot.member_id, amount: -amount, kind: "expiration",
                        label: "Expiration lot ##{lot.id}", order_id: nil)
        lot.update!(remaining: 0, status: "expired")
        removed += amount
        lines << { lot_id: lot.id, member_id: lot.member_id, amount: amount, expires_at: lot.expires_at }
      end
      mark_succeeded!
      Result.new(status: :processed, as_of: @as_of, expired_count: lines.size, units_removed: removed, lines: lines)
    end
  rescue ActiveRecord::RecordNotUnique
    Result.new(status: :duplicate)
  end

  private

  def claim_idempotency_key!
    ProcessedEvent.create!(event_key: @event_key, event_type: "ExpirationRun", status: "processing")
  end

  def mark_succeeded!
    ProcessedEvent.where(event_key: @event_key).update_all(status: "succeeded", updated_at: Time.current)
  end
end
