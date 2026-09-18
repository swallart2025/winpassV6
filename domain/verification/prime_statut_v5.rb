# frozen_string_literal: true

# Preuve d'integration du moteur Prime de Statut sur PostgreSQL reel.
# Reproduit la logique de PrimeStatutEngine (requete SQL -> assiettes par niveau
# -> PrimeStatutMath -> primes individuelles) et verifie les invariants.
require "bigdecimal"
require_relative "../app/services/prime_statut_math"

PSQL = %(psql -h /home/claude/pgsock -p 5433 -U winpass -d winpass_v5 -tAF'|')
def psql(sql) = `#{PSQL} -c "#{sql.gsub('"', '\"')}"`
def run(sql)  = system("#{PSQL} -q -c \"#{sql.gsub('"', '\"')}\" >/dev/null")

POCHE_RATE = BigDecimal("0.05")
PAS        = BigDecimal("0.005")
PLAFOND    = BigDecimal("0.60")

run <<~SQL
  DROP TABLE IF EXISTS pool_contributions; DROP TABLE IF EXISTS member_statuses;
  CREATE TABLE pool_contributions(
    id bigserial PRIMARY KEY, pool_type text, order_id bigint, source_member_id bigint,
    amount numeric(18,6) CHECK(amount<>0), occurred_at timestamp NOT NULL, created_at timestamp DEFAULT now());
  CREATE TABLE member_statuses(member_id bigint UNIQUE, niveau_tenu int, grand_niveau int);
  -- 5 membres a des niveaux differents (poche = 5%% de leur commission)
  INSERT INTO member_statuses(member_id,niveau_tenu,grand_niveau) VALUES
    (1,1,1),(2,5,2),(3,10,3),(4,15,4),(5,20,5),(6,10,3);
  INSERT INTO pool_contributions(pool_type,order_id,source_member_id,amount,occurred_at) VALUES
    ('prime_statut',101,1,1.00,'2026-07-10'),
    ('prime_statut',102,2,2.00,'2026-07-11'),
    ('prime_statut',103,3,3.00,'2026-07-12'),
    ('prime_statut',104,4,4.00,'2026-07-13'),
    ('prime_statut',105,5,5.00,'2026-07-14'),
    -- membre 6 : une commande ANNULEE (positif + compensation negative) -> assiette nette 0
    ('prime_statut',106,6,2.00,'2026-07-15'),
    ('prime_statut',106,6,-2.00,'2026-07-15'),
    -- bruit : un achat AOUT (ne doit pas compter en juillet)
    ('prime_statut',107,3,9.00,'2026-08-02');
SQL

# --- logique du moteur : somme nette par membre sur JUILLET ------------------
rows = psql(%(SELECT source_member_id, SUM(amount)
              FROM pool_contributions
              WHERE pool_type='prime_statut' AND to_char(occurred_at,'YYYY-MM')='2026-07'
              GROUP BY source_member_id ORDER BY source_member_id;)).strip.lines

members = rows.map { |ln| mid, s = ln.strip.split("|"); { member_id: mid.to_i, s: BigDecimal(s) } }
                  .select { |m| m[:s].positive? }
statuses = psql("SELECT member_id, niveau_tenu FROM member_statuses;").strip.lines
             .to_h { |ln| a = ln.strip.split("|"); [a[0].to_i, a[1].to_i] }

n = 20
b_l = Array.new(n + 1, BigDecimal(0))
members.each do |m|
  m[:niveau] = statuses[m[:member_id]] || 1
  m[:b_i]    = m[:s] / POCHE_RATE
  b_l[m[:niveau]] += m[:b_i]
end

res   = PrimeStatutMath.solve(b_l: b_l, poche_rate: POCHE_RATE, pas: PAS, plafond: PLAFOND)
poche = b_l.sum * POCHE_RATE

puts "Membres pris en compte (juillet) : #{members.map { |m| m[:member_id] }.inspect}  (6 exclu = annule ; aout exclu)"
puts "p deduit = %.3f" % res[:p]
primes = members.map do |m|
  ml = res[:majorations][m[:niveau]]
  prime = (ml * m[:b_i]).round(6)
  puts "  membre #{m[:member_id]} niv #{m[:niveau].to_s.rjust(2)} : assiette #{format('%8.2f', m[:b_i])}  " \
       "taux #{format('%.1f', (0.40 + ml) * 100)}%  prime #{format('%.6f', prime)}"
  prime
end
distributed = primes.sum
reserve = poche - distributed

demi  = (1..n).all? { |l| v = (BigDecimal("0.40") + res[:majorations][l]) * 100; ((v * 2) - (v * 2).round).abs < 1e-9 }
crois = (1...n).all? { |i| res[:majorations][i + 1] >= res[:majorations][i] }
n1    = res[:majorations][1].zero?

puts
puts "poche         = #{format('%.6f', poche)}   (attendu 15.000000 : membre 6 et aout exclus)"
puts "distribue     = #{format('%.6f', distributed)}"
puts "reserve       = #{format('%.6f', reserve)}   (>= 0, sous 1 cran)"
puts "taux tous multiples de 0,5 : #{demi} | croissant : #{crois} | N1 = 40%% (majoration nulle) : #{n1}"
puts "sans depassement (distribue <= poche) : #{distributed <= poche}"
