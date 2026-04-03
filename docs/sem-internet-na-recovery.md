# Instalando macOS sem Wi-Fi na Recovery

O macOS Sonoma removeu os drivers nativos do chip Wi-Fi BCM4352 (presente nos
MacBook Pro Mid-2015 e similares). Isso significa que a Recovery não terá Wi-Fi
disponível para baixar e instalar o sistema.

Existem **duas formas** de resolver isso sem precisar que o OpenCore inicie:

---

## Opção 1 — iPhone via USB (Mais simples)

O macOS Recovery reconhece o iPhone como um adaptador Ethernet USB **nativamente**,
sem precisar de nenhum kext ou driver extra.

### Passos

1. Ligue o iPhone no MacBook via cabo Lightning/USB-C
2. No iPhone → **Ajustes → Dados Celulares → Ponto de Acesso Pessoal**
3. Ative **"Permitir Acesso de Outros"**
4. O Mac detecta automaticamente a conexão USB — aguarde o ícone de rede aparecer
5. Prossiga normalmente com a instalação do macOS

> **Dica:** Se o Mac não detectar o iPhone imediatamente, desbloqueie o iPhone
> e toque em **"Confiar"** quando aparecer a notificação de dispositivo novo.

---

## Opção 2 — Instalador Offline com UnPlugged (Sem internet nenhuma)

O [UnPlugged](https://github.com/corpnewt/UnPlugged) é um script que constrói
um instalador completo do macOS dentro da Recovery, sem precisar de internet,
usando o `InstallAssistant.pkg` baixado previamente (~12 GB).

### Por que usar Monterey como base de recovery para instalar Sonoma?

O ambiente de recovery do **Sonoma não consegue montar volumes FAT32 ou ExFAT**
por padrão. Para contornar isso, usa-se o recovery do **Monterey** (que monta
sem problemas) para iniciar o instalador do Sonoma.

### Estrutura do pendrive

```
Pendrive (ex: /dev/sdb)
├── sdb1 — FAT32 ~1GB "OPENCORE"
│   └── com.apple.recovery.boot/
│       ├── BaseSystem.dmg      ← Monterey (não Sonoma!)
│       └── BaseSystem.chunklist
└── sdb2 — ExFAT ~14GB+ "UNPLUGGED"
    ├── InstallAssistant.pkg    ← Sonoma (~12 GB)
    └── UnPlugged.command       ← script do corpnewt
```

### Passos para montar o pendrive (no Linux)

```bash
# Baixar o Monterey BaseSystem (recovery base)
python3 macrecovery.py \
  -b Mac-FFE5EF870D7BA81A \
  -m 00000000000000000 \
  -os latest \
  download

# Baixar Sonoma InstallAssistant.pkg (~12GB) via gibMacOS
# (requer Python 3 e o script gibMacOS.py do corpnewt)
python3 gibMacOS.py

# Particionar o pendrive
parted /dev/sdb --script \
  mklabel gpt \
  mkpart primary fat32 1MiB 1025MiB \
  mkpart primary 1025MiB 100%

mkfs.vfat -F 32 -n "OPENCORE" /dev/sdb1
mkfs.exfat -n "UNPLUGGED" /dev/sdb2

# Copiar Monterey recovery para sdb1
mkdir -p /mnt/oc
mount /dev/sdb1 /mnt/oc
mkdir -p /mnt/oc/com.apple.recovery.boot
cp BaseSystem.dmg BaseSystem.chunklist /mnt/oc/com.apple.recovery.boot/
umount /mnt/oc

# Copiar Sonoma InstallAssistant.pkg + UnPlugged para sdb2
mkdir -p /mnt/unplugged
mount /dev/sdb2 /mnt/unplugged
cp InstallAssistant.pkg /mnt/unplugged/
curl -L https://raw.githubusercontent.com/corpnewt/UnPlugged/main/UnPlugged.command \
  -o /mnt/unplugged/UnPlugged.command
umount /mnt/unplugged
```

### Passos dentro da Recovery (no Mac)

1. Boot pelo pendrive → selecione **macOS Base System** (Monterey)
2. Abra o **Disk Utility** → formata o SSD destino como APFS + GUID
3. Abra o **Terminal**
4. Monte o volume ExFAT manualmente (caso não apareça):
   ```sh
   diskutil list
   mkdir /Volumes/UNPLUGGED
   /sbin/mount_exfat /dev/diskXsY /Volumes/UNPLUGGED
   ```
5. Execute o UnPlugged:
   ```sh
   cd /Volumes/UNPLUGGED
   bash UnPlugged.command
   ```
6. Selecione o volume de destino (o SSD formatado)
7. Escolha **"Fully expand InstallAssistant.pkg"**
8. Aguarde — o instalador do Sonoma será construído e lançado automaticamente

### Após a instalação — aplicar patches OCLP (Wi-Fi, GPU, etc.)

O MBP11,5 precisa de patches pós-instalação do
[OCLP](https://github.com/dortania/OpenCore-Legacy-Patcher/releases) para:
- Wi-Fi (BCM4352 via AirportBrcmFixup)
- GPU AMD R9 M370X (Legacy GCN patches)

Baixe o `OpenCore-Patcher.pkg` em outro computador, copie para um pendrive FAT32,
conecte ao Mac já com Sonoma instalado e execute o `.pkg`. O OCLP cuida do resto.

---

## Comparativo

| Critério | iPhone USB | UnPlugged |
|---|---|---|
| Precisa de internet no Mac | Sim (iPhone compartilha) | Não |
| Download prévio extra | Nenhum | ~12 GB (InstallAssistant.pkg) |
| Complexidade | Muito baixa | Média |
| Funciona sem iPhone | Não | Sim |
| Tempo de instalação | Normal (online) | Normal (offline) |
