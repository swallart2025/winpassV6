# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExpirationEngine do
  before { seed_network! }

  it "expire les lots dont la validité est dépassée et réduit le solde" do
    PurchaseEngine.call(order: order(id: 1, buyer: 410, amount: "400", merchant: "CARREFOUR", at: Time.current),
                        event_key: "ord-1")
    lot = WalletLot.where(member_id: 410).order(:id).first
    lot.update!(expires_at: 2.days.ago) # rendre le lot périmé

    before_balance = Wallet.find_by!(member_id: 410).available_balance
    result = ExpirationEngine.call(as_of: Time.current, event_key: "exp-1")

    expect(result.expired_count).to be >= 1
    expect(lot.reload.status).to eq("expired")
    expect(lot.remaining).to eq(0)
    expect(Wallet.find_by!(member_id: 410).available_balance).to eq(before_balance - lot.initial_amount)
  end
end
