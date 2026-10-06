# Benchmarking & Isolated Execution Suite

Tento adresář obsahuje skripty, konfigurace Dockeru, nástroje a dokumentaci pro lokální a privátní běh testů interoperability DDS-RTPS v izolovaných kontejnerech a pro benchmarking výkonu.

Adresář byl vytvořen za účelem oddělení těchto doplňkových nástrojů od kořenového adresáře repozitáře, aby root repozitáře zůstal co nejblíže původnímu OMG upstreamu (`omg-dds/dds-rtps`).

---

## 📁 Přehled obsahu

### 1. Spouštěcí a benchmarkovací skripty
* [`run_benchmark.sh`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/run_benchmark.sh) – Automatizovaný benchmark testovací sady. Spouští opakovaně `run_tests_parallel.sh` (např. 8× s 16 procesy a 8× se 4 procesy), měří čas a ukládá přejmenované reporty s časovým razítkem a parametry.
* [`run_tests_parallel.sh`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/run_tests_parallel.sh) – Paralelní spouštění testů v nezávislých Docker kontejnerech na lokálním stroji (analogie maticových jobů v GitHub Actions s throttlováním a izolovanými sítěmi).
* [`run_tests_in_docker.sh`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/run_tests_in_docker.sh) – Spustí celou sadu testů v izolovaném kontejneru a vygeneruje XML, XLSX i HTML reporty.
* [`run_in_docker.sh`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/run_in_docker.sh) – Univerzální spouštěč v izolovaném Docker kontejneru (vhodné pro interaktivní bash nebo jednotlivé příkazy).
* [`generate_reports.sh`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/generate_reports.sh) – Slučuje dílčí JUnit XML reporty a generuje přehledný Excel (`interoperability_report.xlsx`) i HTML report (`index.html`).

### 2. Docker konfigurace
* [`Dockerfile`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/Dockerfile) – Definice testovacího kontejneru založeného na Ubuntu 22.04 s tshark, Pythonem 3 a nástroji pro generování reportů.
* [`.dockerignore`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/.dockerignore) – Seznam ignorovaných souborů při sestavení Docker image.
* [`docker-compose.yml`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/docker-compose.yml) – Docker Compose konfigurace pro snadné spuštění testovacího kontejneru.

### 3. RTPS Discovery Sniffer
* [`rtps_discovery_sniffer.py`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/rtps_discovery_sniffer.py) – Nástroj pro odposlech a dekódování RTPS discovery metatrafficu (SPDP/SEDP) pomocí `tshark`.
* [`test_rtps_discovery_sniffer.py`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/test_rtps_discovery_sniffer.py) – Unit testy pro discovery sniffer.

### 4. GitHub Actions self-hosted runner skripty
* [`runner/`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/runner/) – Pomocné skripty pro spouštění GitHub Actions self-hosted runneru (`config.sh`, `env.sh`, `run.sh`, šablony a `safe_sleep.sh`).

### 5. Nástroje a UI
* [`workflow_dispatcher.html`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/workflow_dispatcher.html) – Lokální interaktivní HTML aplikace pro pohodlný výběr vendorů a generování parametrů / spouštění GitHub Actions workflow.

### 6. Dokumentace k síťové izolaci a úpravám
* [`README_DOCKER_ISOLATION.md`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/README_DOCKER_ISOLATION.md) – Detailní rozbor multicastové izolace Dockeru na lokálních strojích a self-hosted runnerech.
* [`README_DISCOVERY.md`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/README_DISCOVERY.md) – Dokumentace k RTPS discovery snifferu.
* [`readme_githubaction.md`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/readme_githubaction.md) – Příručka k GitHub Actions workflow pro interoperabilitu.
* [`readme_load_vendor_files.md`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/readme_load_vendor_files.md) & [`git_load_vendor_files.patch`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/git_load_vendor_files.patch) – Popis stahování vendor executables a příslušný patch.
* [`INTEROPERABILITY_FIXES.md`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/INTEROPERABILITY_FIXES.md) & [`update_readme.md`](file:///d:/prog/polis/Angel-RTI-OMG/MR-dds-rtps/benchmarking/update_readme.md) – Popis oprav interoperability a změn v README.

---

## 🚀 Rychlé použití z kořene repozitáře

```bash
# 1. Spuštění celého benchmarku (paralelní běhy 16 a 4 procesy):
./benchmarking/run_benchmark.sh --runs 4

# 2. Rychlý paralelní test se 4 souběžnými Docker kontejnery:
./benchmarking/run_tests_parallel.sh --jobs 4

# 3. Spuštění testů v jednom Docker kontejneru:
./benchmarking/run_tests_in_docker.sh

# 4. Interaktivní shell v testovacím Docker kontejneru:
./benchmarking/run_in_docker.sh
```
