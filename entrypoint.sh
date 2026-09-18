#!/bin/bash
# Prépare la base puis démarre l'API (qui sert aussi le tableau de bord).
#
# IMPORTANT : ce script est volontairement TOLÉRANT. Aucune étape de préparation
# de base ne doit empêcher le serveur de démarrer — sinon on se retrouve « sans
# port 3000 ». On ne met donc PAS `set -e` : chaque commande de base est isolée,
# et on arrive TOUJOURS au démarrage du serveur.
cd /app

echo "→ Attente de PostgreSQL..."
until pg_isready -h "${DB_HOST:-db}" -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; do sleep 1; done

has_table() { # $1 = env, $2 = table
  RAILS_ENV="$1" bundle exec rails runner "exit(ActiveRecord::Base.connection.table_exists?('$2') ? 0 : 1)" >/dev/null 2>&1
}

prepare_db() { # $1 = RAILS_ENV, $2 = "seed" pour amorcer le réseau de démo
  local env="$1"
  echo "→ Base ($env)..."
  RAILS_ENV="$env" bundle exec rails db:create 2>/dev/null || true
  RAILS_ENV="$env" bundle exec rails db:migrate || true

  # Auto-guérison DOUCE : si une table clé manque encore (base à moitié montée
  # ou schéma obsolète), on tente de rejouer le schéma — mais sans jamais faire
  # échouer le démarrage.
  if ! has_table "$env" payments; then
    echo "  ⤷ tables manquantes : reconstruction du schéma."
    RAILS_ENV="$env" bundle exec rails db:migrate:reset 2>/dev/null \
      || RAILS_ENV="$env" bundle exec rails db:migrate 2>/dev/null \
      || true
  fi

  if [ "$2" = "seed" ]; then
    RAILS_ENV="$env" bundle exec rails db:seed || true
  fi
  return 0
}

prepare_db development seed
prepare_db test

# Si une commande est fournie (ex : rspec), on l'exécute au lieu de démarrer l'API.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# Nettoie un éventuel fichier PID resté d'un arrêt brutal précédent, sinon Rails
# refuse de démarrer (« A server is already running »).
rm -f /app/tmp/pids/server.pid

echo ""
echo "==================================================================="
echo "   Winpass — API + tableau de bord PRÊTS"
echo "   Ouvre le tableau de bord :  http://localhost:3000"
echo ""
echo "   Dans GitHub Codespaces : onglet « PORTS », ligne du port 3000,"
echo "   passe-le en « Public » (clic droit → Port Visibility → Public),"
echo "   puis clique l'icône 🌐 (Open in Browser)."
echo "==================================================================="
echo ""
exec bundle exec rails server -b 0.0.0.0 -p 3000
