# frozen_string_literal: true

require "rails_helper"

# Campagne temps réel : éligibilité, cashback au moment de l'achat, tout-ou-rien.
RSpec.describe "Campagnes (temps réel)" do
  before { seed_network! }

  def buy(id, merchant, buyer: 410, amount: "400", key: nil)
    PurchaseEngine.call(order: order(id: id, buyer: buyer, amount: amount, merchant: merchant, at: Time.current),
                        event_key: key || "ord-#{id}")
  end

  def fund_cic!
    buy(1, "CARREFOUR")
    period = Time.current.strftime("%Y-%m")
    BehavioralMonthlyEngine.call(period: period, event_key: "behav-#{period}", as_of: Time.current)
  end

  it "verse le cashback à un membre éligible et clôture au budget épuisé" do
    fund_cic!
    cic = CicLedger.balance
    campaign = Campaign.create!(category: "Beauté", eligibility_score_max: 20, reward_type: "value",
                               reward_value: bd("0.50"), budget_reserved: bd("0.50"))
    CicLedger.move!(kind: "campaign_reserve", amount: -bd("0.50"), reference: { campaign_id: campaign.id })

    before_balance = Wallet.find_by!(member_id: 410).available_balance
    r = buy(10, "SEPHORA", key: "ord-10") # Beauté : Sophie score 0 <= 20 -> éligible
    expect(r.cashback).to be_present
    expect(r.cashback[:amount]).to eq(bd("0.50"))
    expect(Wallet.find_by!(member_id: 410).available_balance - before_balance).to be >= bd("0.50")
    expect(CampaignReward.where(campaign_id: campaign.id).count).to eq(1)
    expect(campaign.reload.status).to eq("closed") # budget 0,50 épuisé
  end

  it "tout-ou-rien : budget insuffisant pour le bonus entier -> rien versé, campagne stoppée, reliquat à la CIC" do
    fund_cic!
    cic = CicLedger.balance
    campaign = Campaign.create!(category: "Beauté", eligibility_score_max: 20, reward_type: "value",
                               reward_value: bd("5"), budget_reserved: bd("1"))
    CicLedger.move!(kind: "campaign_reserve", amount: -bd("1"), reference: { campaign_id: campaign.id })

    before_balance = Wallet.find_by!(member_id: 410).available_balance
    r = buy(11, "SEPHORA", key: "ord-11")
    expect(r.cashback).to be_nil
    expect(Wallet.find_by!(member_id: 410).available_balance).to eq(before_balance)
    expect(campaign.reload.status).to eq("closed")
    expect(CicLedger.balance).to eq(cic) # reliquat (1 €) rendu
  end
end
