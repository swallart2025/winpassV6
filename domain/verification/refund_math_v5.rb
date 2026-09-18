# frozen_string_literal: true

# Preuve du reglement de remboursement (gouvernance R1-R4) vs exemple chiffre fige.
require "bigdecimal"
require_relative "../app/services/refund_math"

buyer = { nominal: BigDecimal("3.60"), remaining: BigDecimal("1.60") } # consomme 2 -> reste 1.60
sponsors = [{ nominal: BigDecimal("1.60"), remaining: BigDecimal("1.60") }] # parrain intact
fail_any = false

d = RefundMath.settle(order_amount: BigDecimal("400"), buyer: buyer, sponsors: sponsors, sponsor_mode: :buyer_covers)
fail_any |= d[:card_refund] != BigDecimal("396.400000")
puts "mode defaut   : repris #{d[:recoverable_buyer].to_s('F')} | deduit #{d[:card_deduction].to_s('F')} | carte #{d[:card_refund].to_s('F')} (attendu 396.40)"

c = RefundMath.settle(order_amount: BigDecimal("400"), buyer: buyer, sponsors: sponsors, sponsor_mode: :clawback)
fail_any |= c[:card_refund] != BigDecimal("398.000000")
puts "mode clawback : repris #{c[:repris_total].to_s('F')} | deduit #{c[:card_deduction].to_s('F')} | carte #{c[:card_refund].to_s('F')} (attendu 398.00)"

p = RefundMath.settle(order_amount: BigDecimal("400"), buyer: buyer, sponsors: sponsors, ratio: BigDecimal("0.5"), sponsor_mode: :buyer_covers)
puts "partiel 50%   : carte #{p[:card_refund].to_s('F')} (attendu 199.00)"

raise "ECHEC refund math" if fail_any
puts "TOUT VERT"
