# frozen_string_literal: true

require "rails_helper"

# Scénarios à résultats connus rejoués sur PostgreSQL (mêmes cas que la
# vérification de référence). Réseau : Sophie(410) profondeur 3.
RSpec.describe PurchaseEngine do
  before { seed_network! }

  def buy(id:, buyer: 410, amount: "400", rate: "0.02", points: "0", key: nil)
    described_class.call(order: order(id: id, buyer: buyer, amount: amount, rate: rate, points: points),
                         event_key: key || "ord-#{id}")
  end

  describe "achat cash → earn (golden profondeur 3)" do
    it "attribue les montants exacts et conserve le budget" do
      r = buy(id: 1001)
      expect(r.status).to eq(:processed)
      expect(r.personal).to eq(bd("3.6"))
      # David(G1), Bruno(G2), Alice(G3)
      expect(r.sponsorship[300]).to eq(bd("0.730594"))
      expect(r.sponsorship[120]).to eq(bd("0.511416"))
      expect(r.sponsorship[20]).to  eq(bd("0.357990"))
      expect(r.sponsorship.values.sum).to eq(bd("1.6")) # conservation exacte du pool
      expect(balance(410)).to eq(bd("3.6"))
      expect(balance(300)).to eq(bd("0.730594"))
    end

    it "l'invariant comptable tient : Σ(relevé) == solde" do
      buy(id: 1001)
      expect(statements_sum(410)).to eq(balance(410))
      expect(statements_sum(300)).to eq(balance(300))
    end
  end

  describe "idempotence" do
    it "un rejeu de la même clé ne crée aucun doublon" do
      buy(id: 1001)
      again = buy(id: 1001) # même event_key
      expect(again.status).to eq(:duplicate)
      expect(balance(410)).to eq(bd("3.6"))
      expect(EarnLedger.where(order_id: 1001, earn_type: "personal").count).to eq(1)
    end
  end

  describe "concurrence — même clé" do
    it "un seul traitement accepté, l'autre rejeté" do
      res = run_in_parallel(2) { buy(id: 3001, key: "ord-3001") }
      expect(res.count { |r| r.status == :processed }).to eq(1)
      expect(res.count { |r| r.status == :duplicate }).to eq(1)
      expect(EarnLedger.where(order_id: 3001, earn_type: "personal").count).to eq(1)
      expect(balance(410)).to eq(bd("3.6"))
    end
  end

  describe "concurrence — clés différentes (sérialisées)" do
    it "toutes exécutées, solde exact, relevé continu" do
      res = run_in_parallel(6) { |i| buy(id: 4000 + i, amount: "100", key: "ord-#{4000 + i}") }
      expect(res.all? { |r| r.status == :processed }).to be(true)
      expect(balance(410)).to eq(bd("5.4")) # 6 × (100·0,02·0,45) = 6 × 0,90
      expect(statements_sum(410)).to eq(balance(410))
    end
  end

  describe "compression verticale" do
    it "saute un parrain inactif ; les suivants remontent ; budget conservé" do
      suspend!(300) # David inactif
      r = buy(id: 5001)
      expect(r.sponsorship).not_to have_key(300)
      expect(r.sponsorship[120]).to eq(bd("0.941176")) # Bruno passe G1
      expect(r.sponsorship[20]).to  eq(bd("0.658824")) # Alice passe G2
      expect(r.sponsorship.values.sum).to eq(bd("1.6"))
    end
  end

  describe "achat mixte → earn + burn (FEFO)" do
    it "consomme les points ET génère l'earn sur la commande" do
      buy(id: 1001)                    # Sophie a 3,60
      r = buy(id: 2001, points: "2.0") # paie 2,00 en points, rachète 400
      expect(r.status).to eq(:processed)
      expect(r.burn[:amount]).to eq(bd("2.0"))
      expect(balance(410)).to eq(bd("5.2")) # 3,60 − 2,00 + 3,60
      expect(Payment.where(order_id: 2001, status: "settled").count).to eq(1)
      expect(PaymentAllocation.joins(:payment).where(payments: { order_id: 2001 }).count).to be >= 1
      expect(statements_sum(410)).to eq(balance(410))
    end

    it "refuse si le solde est insuffisant (409)" do
      r = buy(id: 2002, points: "10.0") # Sophie n'a rien
      expect(r.status).to eq(:insufficient_balance)
      expect(Payment.where(order_id: 2002).count).to eq(0)
    end
  end
end
