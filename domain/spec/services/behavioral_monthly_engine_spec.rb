# frozen_string_literal: true

require "rails_helper"

# Batch mensuel comportemental — mêmes cas que la vérification de référence.
RSpec.describe BehavioralMonthlyEngine do
  before { seed_network! } # Sophie(410) <- David <- Bruno <- Alice, tous actifs

  def buy(id, merchant, amount: "400")
    PurchaseEngine.call(order: order(id: id, buyer: 410, amount: amount, merchant: merchant, at: Time.current),
                        event_key: "ord-#{id}")
  end

  it "calcule potentiel, score, taux, récompense et contribution CIC" do
    buy(1, "CARREFOUR") # Alimentaire (max 35, min 50) -> rechargé
    buy(2, "FNAC")      # Culture & Loisirs (max 10, min 40) -> rechargé
    period = Time.current.strftime("%Y-%m")

    result = BehavioralMonthlyEngine.call(period: period, event_key: "behav-#{period}", as_of: Time.current)
    line = result.lines.find { |l| l[:member_id] == 410 }

    expect(line[:potential]).to eq(bd("2.4"))       # 2 × (8 × 0,15)
    expect(line[:score]).to eq(45)                  # 35 + 10
    expect(line[:unlocked_rate]).to eq(50)          # barème 40-59 -> 50 %
    expect(line[:reward]).to eq(bd("1.2"))          # 2,40 × 50 %
    expect(line[:cic_contribution]).to eq(bd("1.2"))
    expect(CicLedger.balance).to eq(bd("1.2"))
    expect(MemberMonthlyReward.find_by(member_id: 410, period: period).reward).to eq(bd("1.2"))
  end

  it "est idempotent (rejeu de la même période)" do
    buy(1, "CARREFOUR")
    period = Time.current.strftime("%Y-%m")
    BehavioralMonthlyEngine.call(period: period, event_key: "behav-#{period}", as_of: Time.current)
    again = BehavioralMonthlyEngine.call(period: period, event_key: "behav-#{period}", as_of: Time.current)
    expect(again.status).to eq(:duplicate)
    expect(MemberMonthlyReward.where(member_id: 410, period: period).count).to eq(1)
  end
end
