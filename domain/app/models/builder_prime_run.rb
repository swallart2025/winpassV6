# frozen_string_literal: true

# Marqueur d'exécution de la distribution trimestrielle des primes de rang.
# Sa seule présence (period UNIQUE) prouve que le trimestre a été traité — que des
# primes aient été versées ou non. C'est le vrai garde-fou anti-rejeu (fin du pot
# RFA qui gonfle à chaque clic).
class BuilderPrimeRun < ApplicationRecord
end
