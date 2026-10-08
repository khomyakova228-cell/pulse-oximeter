#!/usr/bin/env bash
# =============================================================================
#  Проверка и выпуск проекта «Пульсоксиметр» (KiCad 9/10, kicad-cli)
#    1. ERC схемы            -> output/reports/erc.rpt
#    2. DRC платы            -> output/reports/drc.rpt   (+ сверка со схемой)
#    3. Gerber + сверловка   -> output/gerber/*, output/pulse_oximeter_gerber.zip
#    4. BOM (перечень)       -> output/pulse_oximeter_BOM.csv
#    5. PDF схемы            -> output/pulse_oximeter_schematic.pdf (+ ч/б для печати)
#
#  Запуск из любой папки:   ./scripts/build.sh
#  Другой kicad-cli:        KICAD_CLI=/путь/kicad-cli ./scripts/build.sh
#  Коды возврата: 0 — ERC и DRC без ошибок (предупреждения допустимы); 1 — есть ошибки ERC/DRC
#                 или шаг не выполнен
#                 (файлы выпускаются в любом случае); 2 — нет kicad-cli или сабмодуля.
# =============================================================================
set -u

PROJECT="pulse_oximeter"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCH="$PROJECT.kicad_sch"
PCB="$PROJECT.kicad_pcb"
OUT="output"
REP="$OUT/reports"
GBR="$OUT/gerber"

# --- поиск kicad-cli ---------------------------------------------------------
find_cli() {
    if [ -n "${KICAD_CLI:-}" ]; then echo "$KICAD_CLI"; return; fi
    if command -v kicad-cli >/dev/null 2>&1; then command -v kicad-cli; return; fi
    for p in /Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli \
             /usr/local/bin/kicad-cli /usr/bin/kicad-cli; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
}
CLI="$(find_cli)"
if [ -z "$CLI" ]; then
    echo "ОШИБКА: kicad-cli не найден. Установите KiCad 9/10 или задайте KICAD_CLI." >&2
    exit 2
fi

# --- библиотека (git-сабмодуль) ---------------------------------------------
if [ ! -f lib/kicad-gost-lib/symbols/GOST_UGO.kicad_sym ]; then
    echo "Сабмодуль lib/kicad-gost-lib не загружен — выполняю git submodule update --init"
    git submodule update --init --recursive || {
        echo "ОШИБКА: не удалось загрузить сабмодуль lib/kicad-gost-lib" >&2; exit 2; }
fi

rm -rf "$OUT"
mkdir -p "$REP" "$GBR"
STATUS=0
step() { printf '\n=== %s ===\n' "$1"; }
# число ошибок/предупреждений в отчёте kicad-cli (строки «; error» / «; warning»)
summary() {
    local e w
    e=$(grep -c '; error' "$1" 2>/dev/null); w=$(grep -c '; warning' "$1" 2>/dev/null)
    echo "  ошибок: ${e:-0}, предупреждений: ${w:-0}  ->  $1"
    [ "${e:-0}" -eq 0 ]
}
fail() { echo "  !! $1"; STATUS=1; }

echo "kicad-cli: $CLI ($("$CLI" version))"

# --- 1. ERC ------------------------------------------------------------------
step "1/5 ERC — проверка электрических правил схемы"
"$CLI" sch erc --severity-all --format report -o "$REP/erc.rpt" "$SCH" || fail "ERC не выполнен"
summary "$REP/erc.rpt" || fail "ERC: есть ошибки"

# --- 2. DRC ------------------------------------------------------------------
step "2/5 DRC — проверка правил проектирования платы"
"$CLI" pcb drc --schematic-parity --severity-all --format report -o "$REP/drc.rpt" "$PCB" || fail "DRC не выполнен"
summary "$REP/drc.rpt" || fail "DRC: есть ошибки"

# --- 3. Gerber + сверловка ---------------------------------------------------
step "3/5 Gerber и файлы сверловки"
"$CLI" pcb export gerbers \
       --layers "F.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts" \
       --subtract-soldermask --no-x2 -o "$GBR/" "$PCB" || fail "Gerber"
"$CLI" pcb export drill --format excellon --excellon-units mm \
       --excellon-separate-th --generate-map --map-format pdf \
       -o "$GBR/" "$PCB" || fail "сверловка"
if command -v zip >/dev/null 2>&1; then
    (cd "$GBR" && zip -q -r "../${PROJECT}_gerber.zip" .) && echo "  архив: $OUT/${PROJECT}_gerber.zip"
else
    tar -czf "$OUT/${PROJECT}_gerber.tar.gz" -C "$GBR" . && echo "  архив: $OUT/${PROJECT}_gerber.tar.gz"
fi

# --- 4. BOM ------------------------------------------------------------------
step "4/5 BOM — перечень элементов"
"$CLI" sch export bom \
       --fields 'Reference,Value,Footprint,${QUANTITY},Manufacturer,Manufacturer_Part_Number' \
       --labels 'Поз. обозначение,Номинал/тип,Корпус,Кол.,Производитель,Партномер' \
       --group-by 'Value,Footprint,Manufacturer_Part_Number' \
       --sort-field 'Reference' --ref-range-delimiter '-' --exclude-dnp \
       -o "$OUT/${PROJECT}_BOM.csv" "$SCH" || fail "BOM"

# --- 5. PDF схемы ------------------------------------------------------------
step "5/5 PDF схемы"
"$CLI" sch export pdf -o "$OUT/${PROJECT}_schematic.pdf" "$SCH" || fail "PDF (цвет)"
"$CLI" sch export pdf --black-and-white -o "$OUT/${PROJECT}_schematic_bw.pdf" "$SCH" || fail "PDF (ч/б)"

# --- итог --------------------------------------------------------------------
step "Итог"
ls -1 "$OUT" | sed 's/^/  /'
if [ $STATUS -eq 0 ]; then echo "  ERC и DRC без ошибок, файлы выпущены."
else echo "  Есть замечания — см. отчёты в $REP/"; fi
exit $STATUS
