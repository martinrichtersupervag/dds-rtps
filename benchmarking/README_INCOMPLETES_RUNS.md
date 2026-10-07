# Neúplné běhy benchmarku (incomplete runs)

Dokument popisuje, proč se v `run_benchmark.sh` mohlo stát, že se neprovedlo
všech 81 párů (9 publisherů × 9 subscriberů), jak se to detekuje a co skripty
dělají při neúplném běhu.

## Příznaky

- běh se nedokončil / po Ctrl-C zůstaly běžet kontejnery,
- junit XML jednotlivých běhů měly různou velikost (např. 694K, 342K, 549K),
  tzn. různý počet párů v reportu - výsledky nebyly srovnatelné,
- běhy se zdánlivě zpomalovaly,
- v logu páru: `docker: Error response from daemon: failed to set up container
  networking: network dds_net_1_... not found`.

## Příčiny

1. **Osiřelé kontejnery.** Ctrl-C ukončil jen obalující bash procesy, ale
   kontejnery spuštěné přes `docker run` zůstaly běžet (nalezeno 24 kontejnerů
   `dds-rtps-tester`, některé starší než 24 hodin). Zabíraly CPU, paměť a
   držely dočasné sítě `dds_net_*`. To zpomalovalo další běhy a pravděpodobně
   vyčerpalo adresní rozsahy Dockeru, takže nové sítě nešly vytvořit.
2. **Tiché ukončení při chybě.** `run_tests_parallel.sh` používá `set -e`.
   Nenulový návratový kód `docker run` ukončil podshell dané funkce dřív, než
   se vypsalo `[FAIL]`, zkopírovalo XML a smazala síť. Pár tak v reportu
   chyběl beze stopy.
3. **Zamlčená chyba při vytvoření sítě.**
   `docker network create ... || true` chybu ignoroval, takže následný
   `docker run` selhal s `network ... not found`.

## Opravy

[run_tests_parallel.sh](run_tests_parallel.sh):

- kontejnery mají label `dds-rtps-benchmark=1` a jméno `ddsrtps_*`;
  při startu i při Ctrl-C se všechny označené kontejnery zabijí a smažou se
  sítě `dds_net_*`,
- chyba z `docker run` se zachytí (`|| exit_code=$?`), pár se vždy vypíše jako
  `[PASS]` / `[FAIL]` a XML se zkopíruje, pokud vznikl,
- vytvoření sítě se zkouší 5× s rostoucí prodlevou, při selhání se vypíše
  `[FAIL] ... cannot create docker network`.

## Detekce a opakování neúplných běhů

### Úroveň páru (`run_tests_parallel.sh`)

- Pár je pokrytý, pokud existuje **neprázdný** soubor
  `junit_report-<pub>---<sub>.xml`.
- Po hlavním průchodu se chybějící páry spustí znovu (jen ty), nejvýše
  `PAIR_RETRIES` krát (výchozí 2). Před každým opakováním se uklidí zbylé
  kontejnery a sítě.
- Pokud některé páry chybí i potom, zapíšou se do
  `.parallel_logs/missing_pairs.txt`, reporty se přesto vygenerují a skript
  skončí s **kódem 3**:

```
==> ERROR: INCOMPLETE RUN - 79/81 pairs have results. Missing:
      - connext_dds-7.7.0---opendds-3.35.0-dev
```

- Při úplném běhu: `==> All 81/81 pairs have results.`

### Úroveň běhu (`run_benchmark.sh`)

- Při kódu 3 se celý běh zopakuje, nejvýše `RUN_RETRIES` krát (výchozí 1).
- Pokud běh zůstane neúplný, soubory se uloží pod běžnými názvy (formát názvů
  se nemění kvůli `compare_junit_reports.py`) a běh se zaznamená.
- Na konci se vypíše souhrn a skript skončí s **kódem 1**:

```
  !!! 1 INCOMPLETE RUN(S) - results are NOT comparable:
      - run 3/8 --jobs 16 [06102026-1946]: connext_dds-7.7.0---opendds-3.35.0-dev
```

- Jiná selhání (kód jiný než 0 a 3) ukončí benchmark okamžitě.

### Nastavení

```bash
PAIR_RETRIES=3 RUN_RETRIES=2 ./run_benchmark.sh
```

## Poznámky

- Kontrola ověřuje jen přítomnost XML, ne počet `<testcase>` uvnitř.
  Reporty lze porovnat ručně počtem testcase v každém junit XML - u srovnatelných
  běhů musí být stejný.
- Ukázka z `results/run2/explain_parallel-self-hosted-run2.txt`
  (běh `par32`, 1 běh ve skupině):

```
##Result for: Parallel-run explanation
================================================================================
ANALYSIS BY PARALLEL-RUN COUNT  (values normalised per single test-suite run)
================================================================================

================================================================================
PARALLEL RUNS: par32   (number of runs in this group: 1)
================================================================================

  -- FLAKY TESTS (inconsistent results across runs) -----------------------------
  Total unique tests in suite set: 105
  Flaky tests (pass in some runs, fail in others): 0  (0.0 %)

  -- OVERALL STATISTICS ---------------------------------------------------------
  Total failures  (avg/run):      0.0  (raw: 0)
  Total passed    (avg/run):    105.0  (raw: 105)
  Total skipped   (avg/run):      0.0  (raw: 0)

  TOP failure areas (QoS / feature):

  TOP failing Publishers (overall):
  TOP failing Subscribers (overall):
```

## Kolik testů má mít úplný běh

Číslo **105** je počet testů v jednom test suite, tj. pro **jednu dvojici**
publisher-subscriber. Stejná sada 105 testů se provádí pro každou dvojici
v matici 9 × 9:

```
105 testů × 81 párů = 8505 <testcase> v úplném běhu
```

To dává smysl a lze to použít jako kontrolu: počet `<testcase>` v
`junit_interoperability_report.xml` musí být násobek 105, u úplného běhu
(bez filtrů `--publishers` / `--subscribers`) přesně 8505. V analýze
(`explain_parallel`) se počítají unikátní názvy testů, proto tam zůstává
105 bez ohledu na počet párů - ukazuje tedy jen velikost jedné sady, nikoli
pokrytí matice.

### Naměřeno v dosavadních výsledcích

| soubor | `<testcase>` | páry (÷105) | úplné? |
|---|---|---|---|
| run2, par32 (06102026-1829) | 105 | 1 | ne |
| run3, par16 (06102026-1854) | 525 | 5 | ne |
| run3, par16 (06102026-1921) | 525 | 5 | ne |
| run3, par16 (06102026-1946) | 525 | 5 | ne |

Všechny dosavadní běhy tedy pokryly jen 1-5 z 81 párů (shoduje se to s pěti
řádky `[PASS]` ve výpisu běhu). Ostatní páry tiše vypadly kvůli chybám popsaným
výše, proto jsou tyto výsledky (včetně časů, např. 1590 s) **nesrovnatelné**
a je třeba je po opravě znovu změřit. Před opravou je nic nehlídalo.

Rychlá kontrola:

```bash
grep -o '<testcase ' junit_interoperability_report.xml | wc -l   # očekáváno 8505
```
