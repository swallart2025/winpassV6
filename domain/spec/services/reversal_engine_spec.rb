# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReversalEngine do
  before { seed_network! }

  def buy(id:, points: "0")
    PurchaseEngine.call(order: order(id: id, points: points), event_key: "ord-#{id}")
  end
  def cancel(order_id) = described_class.call(order_id: order_id, event_key: "rev-#{order_id}")

  describe "annulation d'un achat cash (type earn)" do
    it "reprend l'earn de l'acheteur ET des parrains (cascade)" do
      buy(id: 1001)
      r = cancel(1001)
      expect(r.status).to eq(:processed)
      expect(r.reversal_type).to eq("earn")
      expect(balance(410)).to eq(bd("0"))   # Sophie revient à 0
      expect(balance(300)).to eq(bd("0"))   # David revient à 0
      expect(r.clawback).to eq(bd("5.2"))   # 3,60 + 1,60
    end
  end

  describe "annulation d'un achat mixte (type earn+burn)" do
    it "reprend l'earn et restitue les points" do
      buy(id: 1001)                 # Sophie : 3,60
      buy(id: 2001, points: "2.0")  # Sophie : 5,20 (burn 2 + earn 3,60)
      r = cancel(2001)
      expect(r.reversal_type).to eq("earn+burn")
      expect(r.restored).to eq(bd("2.0"))
      expect(balance(410)).to eq(bd("3.6")) # retour à l'état post-1001
      expect(Payment.find_by(order_id: 2001).status).to eq("reversed")
      expect(statements_sum(410)).to eq(balance(410))
    end
  end

  describe "garde-fous" do
    it "idempotente : une 2e annulation de la même commande est un doublon" do
      buy(id: 1001)
      cancel(1001)
      expect(cancel(1001).status).to eq(:duplicate)
    end

    it "commande inconnue → not_found" do
      expect(cancel(9999).status).to eq(:not_found)
    end
  end
end
