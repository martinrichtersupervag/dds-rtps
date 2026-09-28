# Vendor File Loading

Tento dokument popisuje mechanismus stahování vendor binárních souborů (`shape_main` executables) zavedený patchem [`git_load_vendor_files.patch`](./git_load_vendor_files.patch) do workflow [`.github/workflows/1_run_interoperability_tests.yml`](./.github/workflows/1_run_interoperability_tests.yml).

---

## Proč tato změna?

Původní workflow stahovalo DDS vendor executables přímo z repozitáře `omg-dds/dds-rtps` jako jednorázový krok bez jakéhokoli retry mechanismu a bez podpory lokální cache pro self-hosted runnery. Nová verze přidává:

- **Retry logic** – až 5 pokusů se 5s odstupem, pokud stahování selže nebo vrátí prázdný výsledek
- **Lokální cache** pro self-hosted runnery – přeskočí síť úplně

---

## Logika (rozhodovací strom)

```
┌───────────────────────────────────────┐
│  RUNNER_ENVIRONMENT == "self-hosted"  │
│  && /opt/dds-vendors/ existuje        │
│  && /opt/dds-vendors/ není prázdný    │
└──────────────┬────────────────────────┘
               │
        ┌──────┴──────┐
        │ ANO         │ NE
        ▼             ▼
  cp -r cache     stahuj z omg-dds/dds-rtps
  do zipped_      (gh release download)
  executables/          │
  exit 0          ┌─────┴─────┐
                  │ OK        │ FAIL / 0 souborů
                  ▼           ▼
              exit 0     retry (max 5×, 5s)
                               │
                          ┌────┴────┐
                          │ OK      │ všechny pokusy selhaly
                          ▼         ▼
                       exit 0    exit 1 (job selže)
```

---

## Krok: `Prepare vendor executables`

```yaml
- name: Prepare vendor executables
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    mkdir -p zipped_executables

    # 1) Self-hosted local cache – fastest, no network needed
    if [ "$RUNNER_ENVIRONMENT" = "self-hosted" ] \
        && [ -d "/opt/dds-vendors" ] \
        && [ "$(ls -A /opt/dds-vendors)" ]; then
      echo "Using local /opt/dds-vendors cache."
      cp -r /opt/dds-vendors/* zipped_executables/
      exit 0
    fi

    # 2) Download from omg-dds/dds-rtps with retry (max 5 attempts)
    for i in {1..5}; do
      echo "Attempt $i/5: downloading from omg-dds/dds-rtps..."
      if gh release download \
          --repo omg-dds/dds-rtps \
          --dir zipped_executables \
          --clobber; then
        count=$(find zipped_executables -type f | wc -l)
        if [ "$count" -gt 0 ]; then
          echo "Download OK ($count files)."
          exit 0
        fi
      fi
      if [ "$i" -lt 5 ]; then
        echo "Download incomplete, retrying in 5s..."
        sleep 5
      fi
    done

    echo "ERROR: All download attempts failed." >&2
    exit 1
```

### Chování podle typu runneru

| Runner | Větev 1 (cache) | Větev 2 (download) |
|---|---|---|
| `self-hosted` + `/opt/dds-vendors/` neprázdný | ✅ Použije cache, `exit 0` | Neprovede se |
| `self-hosted` bez cache | ❌ Podmínka nesplněna | ✅ Stahuje z omg-dds |
| `ubuntu-latest` (GitHub hosted) | ❌ `$RUNNER_ENVIRONMENT` není `self-hosted` | ✅ Stahuje z omg-dds |

---

## Konfigurace self-hosted runneru (volitelné)

Pokud chceš přeskočit síťové stahování na self-hosted runneru, předpřiprav vendor soubory:

```bash
sudo mkdir -p /opt/dds-vendors
sudo cp /path/to/vendor/*.zip /opt/dds-vendors/
sudo chmod -R a+r /opt/dds-vendors
```

Workflow pak detekuje neprázdný `/opt/dds-vendors/` a přeskočí stahování.

---

## Soubory

| Soubor | Popis |
|---|---|
| [`git_load_vendor_files.patch`](./git_load_vendor_files.patch) | Patch oproti původnímu stavu v gitu |
| [`.github/workflows/1_run_interoperability_tests.yml`](./.github/workflows/1_run_interoperability_tests.yml) | Workflow s aplikovaným patchem |
