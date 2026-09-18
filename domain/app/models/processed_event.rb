# frozen_string_literal: true

# Pivot de l'idempotence. L'unicité de `event_key` est garantie EN BASE par un
# index unique : deux traitements du même événement (rejeu ou appels concurrents)
# ne peuvent pas coexister — l'insertion en doublon lève
# ActiveRecord::RecordNotUnique, que le moteur intercepte pour renvoyer
# « duplicate ».
#
# On n'ajoute VOLONTAIREMENT pas de `validates :event_key, uniqueness: true` :
# cette validation applicative est sujette aux conditions de course (elle lit
# avant d'écrire) et masquerait l'erreur de base par une RecordInvalid. La
# contrainte de base est la seule garantie fiable.
class ProcessedEvent < ApplicationRecord
  validates :event_key, presence: true
  validates :event_type, presence: true
end
