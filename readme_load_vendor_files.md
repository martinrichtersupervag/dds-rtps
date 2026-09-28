# Vendor File Loading – Mirror-First Strategy

Tento dokument popisuje mechanismus stahování vendor binárních souborů (`shape_main` executables) zavedený patchem [`git_load_vendor_files.patch`](./git_load_vendor_files.patch) do workflow [`.github/workflows/1_run_interoperability_tests.yml`](./.github/workflows/1_run_interoperability_tests.yml).

---

## Proč tato změna?

Původní workflow stahovalo DDS vendor executables přímo z repozitáře `omg-dds/dds-rtps` při každém spuštění.  
To způsobovalo:

- **Zbytečnou závislost na dostupnosti externího repozitáře** při každém CI běhu
- **Pomalé stahování** pro self-hosted runnery bez vlastní cache
- **Žádnou redundanci** – při výpadku zdroje celý job selhal

Nová strategie zavádí **mirror-first přístup** s lokální cache a SHA256 ověřením integrity.

---

## Přehled logiky (rozhodovací strom)

```
┌─────────────────────────────────┐
│    RUNNER_ENVIRONMENT?          │
└──────────┬──────────────────────┘
           │
     ┌─────┴──────────────┐
     │ self-hosted        │ ubuntu-latest (nebo jiný)
     ▼                    ▼
/opt/dds-vendors       cache=false (vždy)
existuje & neprázdný?  → stáhni z mirroru
     │
  ┌──┴──┐
  │ ANO │ NE
  ▼     ▼
cache  cache=false
=true  → stáhni z mirroru
  │            │
  ▼            ▼
cp -r      Mirror download
cache      (martinrichtersupervag/
do zipped_  dds-vendor-mirror)
executables/       │
               ┌───┴──────┐
               │ OK       │ FAILURE
               │          ▼
               │   Fallback: stáhni
               │   z omg-dds/dds-rtps
               │          │
               └────┬─────┘
                    ▼
             Retry loop (max 5×, 5s)
                    │
                    ▼
          SHA256 ověření všech .zip
                    │
                    ▼
          unzip → executables/
```

---

## Popis jednotlivých kroků

### 1. `Check local vendor cache`

```yaml
- name: Check local vendor cache
  id: vendor_cache
  run: |
    # Local /opt/dds-vendors cache is only meaningful on self-hosted runners.
    # GitHub-hosted (ubuntu-latest) VMs are ephemeral – always download.
    if [ "$RUNNER_ENVIRONMENT" = "self-hosted" ] \
        && [ -d "/opt/dds-vendors" ] \
        && [ "$(ls -A /opt/dds-vendors)" ]; then
      echo "cache=true" >> $GITHUB_OUTPUT
    else
      echo "cache=false" >> $GITHUB_OUTPUT
    fi
```

Krok **vždy běží** (bez `if:` podmínky v YAML), ale uvnitř shell skriptu se větví podle proměnné prostředí `$RUNNER_ENVIRONMENT`:

| Runner | `$RUNNER_ENVIRONMENT` | Výsledek |
|---|---|---|
| `self-hosted` (vlastní stroj) | `self-hosted` | Zkontroluje `/opt/dds-vendors`, vrátí `true`/`false` |
| `ubuntu-latest` (GitHub Azure) | prázdný / jiný | Vždy vrátí `cache=false`, `/opt/` se nekontroluje |

> **Proč shell podmínka místo YAML `if:`?**  
> Kdyby existovaly dva samostatné kroky s různými `id`, navazující kroky referencující `steps.vendor_cache.outputs.cache` by na jednom z runnerů vždy dostaly prázdnou hodnotu, což by rozbilo podmínky `== 'false'`. Jeden krok s jedním `id` zaručí, že výstup `cache` je vždy nastaven.

---

### 2. `Download vendor assets from mirror`

```yaml
- name: Download vendor assets from mirror
  if: steps.vendor_cache.outputs.cache == 'false'
  id: download_mirror
  continue-on-error: true
  uses: robinraju/release-downloader@v1.13
  with:
    repository: "martinrichtersupervag/dds-vendor-mirror"
    latest: true
    fileName: "*"
    out-file-path: zipped_executables
```

Primární zdroj: vlastní mirror repozitář [`martinrichtersupervag/dds-vendor-mirror`](https://github.com/martinrichtersupervag/dds-vendor-mirror).  
`continue-on-error: true` zajistí, že selhání mirroru nezdeplikuje celý workflow – místo toho se aktivuje fallback.

---

### 3. `Fallback download from OMG DDS`

```yaml
- name: Fallback download from OMG DDS
  if: steps.vendor_cache.outputs.cache == 'false' && steps.download_mirror.outcome == 'failure'
  uses: robinraju/release-downloader@v1.13
  with:
    repository: "omg-dds/dds-rtps"
    latest: true
    fileName: "*"
    out-file-path: zipped_executables
```

Aktivuje se pouze tehdy, pokud download z mirroru selhal (`outcome == 'failure'`).  
Fallback na originální upstream zdroj [`omg-dds/dds-rtps`](https://github.com/omg-dds/dds-rtps).

---

### 4. `Retry vendor downloads (max 5 attempts)`

```yaml
- name: Retry vendor downloads (max 5 attempts)
  if: steps.vendor_cache.outputs.cache == 'false'
  run: |
    for i in {1..5}; do
      count=$(find zipped_executables -type f | wc -l)
      if [ "$count" -gt 0 ]; then
        echo "Vendor assets present."
        break
      fi
      echo "Retrying vendor download in 5s (attempt $i)..."
      sleep 5
      gh release download --repo martinrichtersupervag/dds-vendor-mirror --dir zipped_executables || true
    done
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Ochranná smyčka – pokud je složka `zipped_executables` stále prázdná, pokusí se znovu stáhnout přes `gh` CLI z mirroru (max 5 pokusů s 5s odstupem).  
Vyžaduje: `secrets.GITHUB_TOKEN` (standardně dostupný v GitHub Actions).

---

### 5. `Use local vendor cache`

```yaml
- name: Use local vendor cache
  if: steps.vendor_cache.outputs.cache == 'true'
  run: cp -r /opt/dds-vendors/* zipped_executables/
```

Pokud local cache existuje, jednoduše překopíruje obsah do pracovního adresáře. **Žádné sítové požadavky.**

---

### 6. `Verify SHA256 integrity of vendor ZIPs`

```yaml
- name: Verify SHA256 integrity of vendor ZIPs
  run: |
    cd zipped_executables
    for f in *.zip; do
      echo "Verifying SHA256 for $f"
      sha256sum "$f"
    done
```

Vypočítá a zaloguje SHA256 hash každého staženého/zkopírovaného ZIP souboru.  
Výstupy jsou viditelné v GitHub Actions logu – lze je použít k manuálnímu ověření integrity nebo pro budoucí automatické porovnávání s checksumem.

> **Aktuálně:** krok pouze loguje hashe (neporovnává s referenčními hodnotami). Pro striktní validaci by bylo potřeba přidat soubor se seznamem očekávaných hashů.

---

## Konfigurace self-hosted runneru

Pro optimální výkon na self-hosted runneru předpřipravte vendor soubory:

```bash
sudo mkdir -p /opt/dds-vendors
# Nakopírujte vendor ZIP soubory (např. z předchozího stažení)
sudo cp /path/to/vendor/*.zip /opt/dds-vendors/
sudo chmod -R a+r /opt/dds-vendors
```

Workflow pak automaticky detekuje cache a přeskočí veškeré stahování.

---

## Soubory

| Soubor | Popis |
|---|---|
| [`git_load_vendor_files.patch`](./git_load_vendor_files.patch) | Hlavní patch – přidává mirror-first logiku |
| [`git_load_vendor_files.patch.blb`](./git_load_vendor_files.patch.blb) | Alternativní varianta patche (odlišný out-file-path: `vendor/`, navíc odstraňuje sync-back krok) |
| [`git_load_vendor_files.patch.blb2`](./git_load_vendor_files.patch.blb2) | Záloha hlavního patche (obsahuje SHA256 verify krok) |
| [`.github/workflows/1_run_interoperability_tests.yml`](./.github/workflows/1_run_interoperability_tests.yml) | Cílový workflow soubor s aplikovaným patchem |

---

## Rozdíly mezi variantami patche

| Vlastnost | `.patch` (hlavní) | `.patch.blb` |
|---|---|---|
| Output adresář | `zipped_executables` | `vendor/` |
| SHA256 verify krok | ✅ Ano | ❌ Ne |
| Odstraňuje sync-back krok | ❌ Ne | ✅ Ano |
| Kontext patche | Od řádku 86 (job steps) | Od řádku 1 + řádku 128 |

Aplikovaný patch je **hlavní varianta** (`git_load_vendor_files.patch`) s výstupem do `zipped_executables/` a SHA256 ověřením.
