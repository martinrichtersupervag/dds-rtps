#!/bin/bash
set -e

# Přejít do adresáře skriptu
cd "$(dirname "$0")"

# Odstranění předchozího sloučeného XML, aby se neslučovalo samo do sebe
rm -f junit_interoperability_report.xml

echo "[1/3] Slučuji XML reporty do junit_interoperability_report.xml..."
python3 -m junitparser merge *.xml junit_interoperability_report.xml

echo "[2/3] Generuji Excel report interoperability_report.xlsx..."
python3 generate_xlsx_report.py --input junit_interoperability_report.xml --output interoperability_report.xlsx

echo "[3/3] Generuji HTML report index.html..."
npx -y xunit-viewer --results=./junit_interoperability_report.xml --output=./index.html

echo "Hotovo! Vygenerované výstupy:"
ls -lh junit_interoperability_report.xml interoperability_report.xlsx index.html
