# frozen_string_literal: true

# Preuve de la mecanique des freins du statut acheteur (spec section 10 : Sofia).
# Reproduit la logique de StatusMonthlyEngine#apply_freins de facon pure.
SURSIS = 3
GAR    = 6
PARGAR = 1
def gn(n) = ((n - 1) / 4) + 1
def plancher(g) = ((g - 1) * 4) + 1

def apply(st, merite, idx)
  if merite >= st[:tenu]
    st[:entree] = idx if gn(merite) != st[:gn]
    st[:tenu] = merite; st[:gn] = gn(merite); st[:repli] = 0
  else
    st[:repli] += 1
    if st[:repli] > SURSIS
      pl = plancher(st[:gn]); mois = idx - st[:entree]
      if mois >= GAR && merite < pl
        st[:gn] = [1, st[:gn] - PARGAR].max; st[:entree] = idx; pl = plancher(st[:gn])
      end
      st[:tenu] = [merite, pl].max; st[:gn] = gn(st[:tenu])
    end
  end
  st[:tenu]
end

st = { tenu: 19, gn: 5, repli: 0, entree: 0 }
suite   = (1..12).map { |idx| apply(st, 6, idx) }
attendu = [19, 19, 19, 17, 17, 13, 13, 13, 13, 13, 13, 9]
puts "descente Sofia obtenu  : #{suite.inspect}"
puts "descente Sofia attendu : #{attendu.inspect}"
puts "conforme : #{suite == attendu}"
raise "ECHEC freins" unless suite == attendu
puts "montee immediate (merite 19) -> #{apply(st, 19, 13)} (attendu 19)"
