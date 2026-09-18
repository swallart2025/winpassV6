# frozen_string_literal: true

# V6 — Compteur global des AUTRES poches, côté membre (purement informationnel).
# Seuls les 40 % « générosité » alimentent le cashback dépensable ; les autres
# poches (Prime de Statut, Grande Galerie, Bâtisseurs, fonctionnement, parrainage
# reçu) sont ici cumulées pour affichage, en euros, sans être converties.
class MemberPocheCounter < ApplicationRecord
  validates :member_id, presence: true, uniqueness: true

  # Total « autres poches » (hors cashback), pour l'affichage du compteur global.
  def total_autres
    prime_statut + comportemental + grands_leaders + fonctionnement + parrainage_recu
  end
end
