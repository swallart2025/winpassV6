#!/usr/bin/env bash
# Recette complète Winpass V5 — à rejouer avant chaque livraison.
# 1) syntaxe Ruby de tous les fichiers ; 2) preuves pures (Ruby) ; 3) preuves PostgreSQL.
set -u
cd "$(dirname "$0")/.." || exit 2
PASS=0; FAIL=0
ok(){ echo "  [OK]   $1"; PASS=$((PASS+1)); }
ko(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 1. Syntaxe Ruby (tous les fichiers) =="
ERR=0
while IFS= read -r f; do ruby -c "$f" >/dev/null 2>&1 || { echo "    ruby -c KO: $f"; ERR=1; }; done < <(find app db config -name '*.rb')
[ $ERR -eq 0 ] && ok "ruby -c sur tous les .rb" || ko "ruby -c"

echo "== 2. Preuves pures (Ruby) =="
for t in prime_statut_math_v5 status_freins_v5 batisseurs_v5 refund_math_v5; do
  if ruby "verification/$t.rb" >/tmp/$t.log 2>&1; then ok "$t"; else ko "$t (voir /tmp/$t.log)"; fi
done

echo "== 3. Preuves PostgreSQL =="
export PATH=/usr/lib/postgresql/16/bin:$PATH
PGH=/home/claude/pgsock
pg_ctl -D /home/claude/pgdata status >/dev/null 2>&1 || \
  pg_ctl -D /home/claude/pgdata -o "-k $PGH -p 5433 -c listen_addresses=" -l /home/claude/pglog/pg.log start >/dev/null 2>&1
sleep 2
PSQL="psql -h $PGH -p 5433 -U winpass -d winpass_v5 -v ON_ERROR_STOP=1 -q"
if $PSQL -f verification/pools_v5.sql >/tmp/pools.log 2>&1; then ok "pools_v5.sql (B2/B4/B6)"; else ko "pools_v5.sql"; fi
if $PSQL -f verification/refund_pending_v5.sql >/tmp/refpend.log 2>&1; then ok "refund_pending_v5.sql (R6/pending)"; else ko "refund_pending_v5.sql"; fi
if ruby verification/prime_statut_v5.rb >/tmp/ps_db.log 2>&1; then ok "prime_statut_v5.rb (integration DB)"; else ko "prime_statut_v5.rb (voir /tmp/ps_db.log)"; fi

echo "== 4. Non-régression V4 (harnais Python sur vrai PostgreSQL) =="
V4=../verification
export WINPASS_DSN="dbname=winpass_test user=winpass host=$PGH port=5433"
createdb -h "$PGH" -p 5433 -U winpass winpass_test >/dev/null 2>&1
psql -h "$PGH" -p 5433 -U winpass -d winpass_test -q -f "$V4/schema_v2_reference.sql" >/dev/null 2>&1
psql -h "$PGH" -p 5433 -U winpass -d winpass_test -q \
  -c "ALTER TABLE wallet_lots ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';" >/dev/null 2>&1
for h in reversal_v4 rollback_v4 concurrency_v4 run_tests_v3; do
  if python3 "$V4/$h.py" >/tmp/$h.log 2>&1; then ok "$h"; else ko "$h (voir /tmp/$h.log)"; fi
done

echo
echo "==================== RECETTE V5 : $PASS OK / $FAIL FAIL ===================="
[ $FAIL -eq 0 ] && echo "TOUT VERT — livraison autorisée" || echo "ECHECS — livraison bloquée"
exit $FAIL
