# Síťová izolace Docker kontejnerů pro DDS-RTPS testy

Tento dokument popisuje mechanismus **úplné síťové izolace Docker kontejnerů** pro testování interoperability protokolu DDS-RTPS. Izolace řeší problém nežádoucího vzájemného rušení (cross-talk) a falešných chyb `Failure – unexpected QoS incompatibility` při paralelním běhu testů na jednom hostitelském stroji (self-hosted runner).

---

## 1. Problém: Multicast Cross-Talk na výchozím Docker bridgi

### Příčina problému
Při standardním spuštění kontejnerů (`docker run` bez volby `--network`) Docker připojuje všechny kontejnery do výchozí bridge sítě `docker0`.

Protokol DDS-RTPS (podle OMG specifikace) realizuje objevování účastníků (**SPDP** — *Simple Participant Discovery Protocol*) prostřednictvím UDP multicastu:
- **Multicastová adresa:** `239.255.0.1`
- **Port:** `7400` (pro výchozí DDS doménu `domainId = 0`)
- **Název testovacího tématu:** `Square` (shodný pro téměř všechny interoperability testy)

Pokud na stejném hostitelském stroji běží více kontejnerů současně (např. 4 maticové úlohy v GitHub Actions na self-hosted runneru nebo 8 souběhů v `run_tests_parallel.sh`), jádro Linuxu na rozhraní `docker0` přeposílá multicastové pakety **do všech ostatních kontejnerů**.

### Důsledky pro testy
Když kontejner **A** testuje *Durability* QoS a kontejner **B** souběžně testuje *Ownership*, *Deadline* nebo *Presentation* QoS:
1. Publisher v kontejneru A zachytí přes multicast zprávu subscribera z kontejneru B na tématu `Square`.
2. Dojde k pokusu o navázání spojení, ale parametry QoS se neshodují.
3. DDS stack vyvolá callbacky:
   - `on_offered_incompatible_qos()`
   - `on_requested_incompatible_qos()`
4. Návratový kód aplikace se změní z očekávaného `OK` na `INCOMPATIBLE_QOS`.
5. Test selže jako **`FAILED (got INCOMPATIBLE_QOS, expected OK)`** – tedy falešná nekompatibilita QoS způsobená cizím testem.

V logu testu, kde měl být pouze 1 publisher a 1 subscriber, se pak typicky objevovaly záznamy jako:
```text
on_subscription_matched() : matched writers 1
on_subscription_matched() : matched writers 2
on_subscription_matched() : matched writers 3 ... až 6!
on_offered_incompatible_qos() : 6 (OWNERSHIP)
on_offered_incompatible_qos() : 4 (DEADLINE)
on_offered_incompatible_qos() : 3 (PRESENTATION)
on_requested_incompatible_qos() : 2 (DURABILITY)
```

Na **GitHub-hosted runnerech (`ubuntu-latest`)** k tomuto problému nedochází, protože každá buňka matice běží ve vlastním izolovaném virtuálním stroji v Azure. Na **self-hosted runnerech** bylo nutné izolaci zajistit na úrovni Dockeru.

---

## 2. Analýza: Proč původní poznámka `(bridge network, contained multicast)` nestačila

V původní verzi skriptu `run_in_docker.sh` se nacházela poznámka a výpis:
```bash
echo "==> Running in isolated Docker container (bridge network, contained multicast)..."
# - Default bridge network isolates multicast discovery (239.255.0.1) from local LAN
```

Původní záměr byl logický, ale narážel na jemný technický detail síťového stacku Dockeru:

### 1. Co původní řešení skutečně izolovalo (vnější fyzická síť)
Komentář měl pravdu v tom, že výchozí bridge `docker0` **izoluje multicast vůči fyzické síti LAN** (např. kancelářské ethernet/Wi-Fi síti). Linuxové jádro a standardní pravidla firewallu nepustí multicastové rámce z virtuálního rozhraní `docker0` ven na fyzickou síťovou kartu hostitele (`eth0`). V tomto ohledu byl multicast skutečně *"contained"* — testy nerušily ostatní počítače v lokální síti.

### 2. V čem spočívala skrytá past (vnitřní L2 switch mezi kontejnery)
Předpokládalo se, že když má každý kontejner vlastní síťový namespace (`netns`) a vlastní IP adresu (např. `172.17.0.2`, `172.17.0.3`), jsou kontejnery izolované.
To však platí pouze pro **unicast**.
- Výchozí Docker síť `bridge` je v jádře Linuxu realizována jako **jeden společný virtuální ethernetový switch** (`docker0`).
- Jakmile je spuštěn kontejner bez explicitního parametru `--network`, jeho virtuální rozhraní (`veth`) je zapojeno do tohoto jediného společného switche.
- Když kontejner A vyšle DDS discovery multicast na `239.255.0.1:7400`, switch `docker0` se zachová jako kterýkoliv ethernetový switch a **rozešle (floodne) tento L2 multicastový rámec do všech ostatních portů** — tedy do kontejneru B, C i D.

### 3. Proč se problém neprojevil dříve?
- **Při sekvenčním běhu:** Dokud běžel v Dockeru vždy jen jeden kontejner v čase, byl na switchi `docker0` sám a žádné cizí pakety neexistovaly.
- **Na GitHub Azure (`ubuntu-latest`):** Každý maticový job běží na vlastním virtuálním stroji v cloudu, kde má svůj vlastní izolovaný Docker daemon a vlastní `docker0`.
- **Zlom nastal na self-hosted runneru:** Jakmile byl zaveden paralelní běh na jednom fyzickém stroji (maticové joby s `max-parallel: 4` v GitHub Actions nebo lokální `run_tests_parallel.sh --jobs 8`), všechny kontejnery se ocitly na témže virtuálním switchi `docker0` a začaly si navzájem rušit testy.

---

## 3. Princip řešení: Dedikovaná síť pro každý kontejner

Řešením je **dynamické vytvoření samostatné Docker sítě pro každý běžící kontejner (nebo testovaný pár)**.

```
       Hostitelský systém (Self-Hosted Runner)
┌────────────────────────────────────────────────────────┐
│                                                        │
│  ┌───────────────────────┐    ┌─────────────────────┐  │
│  │  Docker Net: dds_net_1│    │ Docker Net:dds_net_2│  │
│  │  (Linux bridge br-1)  │    │ (Linux bridge br-2) │  │
│  │  ┌─────────────────┐  │    │ ┌─────────────────┐ │  │
│  │  │   Kontejner 1   │  │    │ │   Kontejner 2   │ │  │
│  │  │  (Pár Connext   │  │    │ │  (Pár FastDDS   │ │  │
│  │  │    × OpenDDS)   │  │    │ │    × DustDDS)   │ │  │
│  │  │                 │  │    │ │                 │ │  │
│  │  │ Multicast 7400  │  │    │ │ Multicast 7400  │ │  │
│  │  │ zůstává pouze   │  │    │ │ zůstává pouze   │ │  │
│  │  │ uvnitř br-1     │  │    │ │ uvnitř br-2     │ │  │
│  │  └─────────────────┘  │    │ └─────────────────┘ │  │
│  └───────────────────────┘    └─────────────────────┘  │
│             ▲                            ▲             │
│             └─────── ŽÁDNÝ MULTICAST ────┘             │
│                      CROSS-TALK                        │
└────────────────────────────────────────────────────────┘
```

### Proč to funguje:
1. Každá uživatelem definovaná síť typu `bridge` vytváří v jádře Linuxu dedikované bridge rozhraní (`br-<id>`).
2. Linuxový bridge neforwarduje L2 multicast pakety na jiná bridge rozhraní.
3. Multicast discovery (SPDP na `239.255.0.1:7400`) je hermeticky uzavřen v rámci jedné sítě.
4. Publisher a Subscriber daného testu (běžící uvnitř téhož kontejneru) spolu bez omezení komunikují přes rozhraní `eth0` / `lo`.

---

## 4. Implementace v repozitáři

Mechanismus je zaveden ve všech spouštěcích skriptech:

### 1. `run_in_docker.sh` (GitHub Actions workflow na self-hosted)
Používá se v workflow `.github/workflows/1_run_interoperability_tests.yml`. Před spuštěním každého kontejneru vygeneruje unikátní název sítě, vytvoří ji, připojí kontejner a po skončení síť spolehlivě zlikviduje:

```bash
# Vygenerování unikátního ID sítě
NET_ID=$(tr -dc 'a-z0-9' < /proc/sys/kernel/random/uuid 2>/dev/null | head -c 8 || echo $RANDOM)
DOCKER_NET="dds_net_${$}_${NET_ID}"
docker network create "$DOCKER_NET" >/dev/null

cleanup_network() {
    docker network rm "$DOCKER_NET" >/dev/null 2>&1 || true
}
trap cleanup_network EXIT INT TERM

# Spuštění s izolovanou sítí
docker run --rm \
    --network "$DOCKER_NET" \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    ...
```

### 2. `run_tests_parallel.sh` (Lokální paralelní běh)
Umožňuje spouštět desítky interoperability testů souběžně (např. `--jobs 8` nebo 16):
- Funkce `run_pair()` pro každý testovaný pár vytváří vlastní `dds_net_${idx}_${rand_id}`.
- Po dokončení páru je síť smazána.
- Na začátku skriptu probíhá preventivní pročištění visících dočasných sítí.
- Obsahuje globální `trap cleanup_parallel INT TERM`, který při stisku `Ctrl+C` ukončí běžící subprocesy a odstraní všechny vytvořené dočasné sítě.

### 3. `discovery/run_discovery_and_interop_tests_in_docker.sh`
Konzistentně doplněna dedikovaná síť i do skriptu pro jednorázové spuštění celé testovací sady uvnitř kontejneru.

---

## 5. Ověření a diagnostika

### Kontrola běžících dočasných sítí
Během testování lze ověřit existenci izolovaných sítí:
```bash
docker network ls --filter "name=dds_net_"
```

### Výsledek testu izolace
Po dokončení testů by seznam dočasných sítí měl být prázdný:
```bash
docker network ls | grep dds_net || echo "Všechny sítě řádně uklizeny"
```

### Manuální úklid (v případě tvrdého pádu systému)
Pokud by došlo k náhlému restartu systému nebo násilnému zabití procesu (`kill -9`):
```bash
docker network ls --filter "name=dds_net_" -q | xargs -r docker network rm
```

---

## 6. Shrnutí přínosů

| Vlastnost | Před úpravou (výchozí `docker0`) | Po úpravě (dedikované sítě) |
|---|---|---|
| **Multicast SPDP (`239.255.0.1`)** | Přeposílán mezi všemi kontejnery | Uzavřen pouze uvnitř jedné sítě |
| **Paralelní běh na self-hosted** | Nebezpečný (náhodné falešné chyby) | Zcela deterministický a stabilní |
| **Výsledky self-hosted vs Azure** | Odlišné (více selhání na self-hosted) | Identické |
| **Zátěž a režie** | Stejná | Zanedbatelná (vytvoření/smazání sítě trvá `< 50 ms`) |
