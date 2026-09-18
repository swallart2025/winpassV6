# frozen_string_literal: true

# V5.1 — Garde-fou d'idempotence RÉEL pour la distribution trimestrielle des
# primes de rang Bâtisseurs.
#
# Problème corrigé : l'ancien garde-fou testait l'existence de `builder_prime_rewards`
# pour la période. Or si AUCUN leader n'est rangé (donc aucune prime versée), aucune
# ligne n'est créée -> le garde-fou ne se déclenche jamais -> chaque clic ré-ajoutait
# la poche 7,5 % au pot RFA (« poche infinie »). On matérialise désormais le passage
# du trimestre par une ligne-marqueur UNIQUE, indépendante de tout versement.
class V5BuilderPrimeRunsAndGuards < ActiveRecord::Migration[7.2]
  def change
    create_table :builder_prime_runs do |t|
      t.string  :period,       null: false            # 'YYYY-Qn'
      t.integer :year,         null: false
      t.decimal :pocket_added, precision: 18, scale: 6, null: false, default: 0
      t.decimal :distributed,  precision: 18, scale: 6, null: false, default: 0
      t.timestamps
    end
    add_index :builder_prime_runs, :period, unique: true
  end
end
