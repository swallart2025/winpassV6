# frozen_string_literal: true

require "rails_helper"

# Purge / rollback du batch mensuel comportemental : rejouable au banc d'essai,
# en conservant les récompenses déjà utilisées (acquises).
RSpec.describe BehavioralRollback do
  before { seed_network! } # Sophie(410) <- David <- Bruno <- Alice

  let(:period) { Time.current.strftime("%Y-%m") }

  def buy(id, merchant, amount: "400", points: "0")
    PurchaseEngine.call(order: order(id: id, buyer: 410, amount: amount, merchant: merchant, at: Time.current, points: points),
                        event_key: "ord-#{id}")
  end

  def run_batch(key)
    BehavioralMonthlyEngine.call(period: period, event_key: key, as_of: Time.current)
  end

  def compo_lot(member = 410)
    earn = EarnLedger.where(member_id: member, earn_type: "comportemental").order(:id).last
    earn && WalletLot.find_by(earn_id: earn.id)
  end

  it "réinitialise une récompense INTACTE, puis la recalcule au rejeu" do
    buy(1, "CARREFOUR")
    buy(2, "FNAC")
    run_batch("b1")
    reward = MemberMonthlyReward.find_by(member_id: 410, period: period).reward
    expect(reward).to eq(bd("1.2"))
    before = balance(410)

    r = BehavioralRollback.call(period: period, event_key: "purge-1")
    expect(r.rolled_back).to include(410)
    expect(MemberMonthlyReward.where(member_id: 410, period: period)).to be_empty
    expect(balance(410)).to eq(before - reward)         # crédit repris
    expect(compo_lot.status).to eq("reversed")          # lot neutralisé
    expect(statements_sum(410)).to eq(balance(410))     # invariant conservé

    run_batch("b2")                                     # rejeu
    expect(MemberMonthlyReward.find_by(member_id: 410, period: period).reward).to eq(reward)
    expect(balance(410)).to eq(before)                  # récompense re-versée à l'identique
  end

  it "CONSERVE une récompense utilisée et ne la re-verse pas au rejeu" do
    buy(1, "CARREFOUR")
    buy(2, "FNAC")
    run_batch("b1")
    # Dépense la totalité du solde (dont la récompense) -> lot comportemental consommé.
    buy(3, "CARREFOUR", amount: "500", points: balance(410).to_s)
    expect(compo_lot.status).to eq("consumed")

    r = BehavioralRollback.call(period: period, event_key: "purge-1")
    expect(r.kept).to include(410)
    expect(MemberMonthlyReward.find_by(member_id: 410, period: period)).to be_present

    run_batch("b2")                                     # rejeu
    expect(MemberMonthlyReward.where(member_id: 410, period: period).count).to eq(1) # pas de double versement
  end

  it "annule la contribution à la CIC des membres réinitialisés" do
    buy(1, "CARREFOUR")
    buy(2, "FNAC")
    run_batch("b1")
    expect(CicLedger.balance).to eq(bd("1.2"))
    BehavioralRollback.call(period: period, event_key: "purge-1")
    expect(CicLedger.balance).to eq(bd("0"))            # contribution annulée
  end
end
