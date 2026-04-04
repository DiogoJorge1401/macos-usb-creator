# Como usar o OCLP (OpenCore Legacy Patcher) apos instalar o macOS

Guia passo a passo para ativar WiFi, Bluetooth, GPU e audio no MacBook Pro 2015
apos instalar macOS Sonoma/Sequoia pelo nosso instalador offline.

---

## O que e o OCLP?

O OCLP (OpenCore Legacy Patcher) e uma ferramenta que aplica **root patches**
no macOS. A Apple removeu drivers de hardware antigo (WiFi BCM4360, GPUs AMD/Intel
legacy, etc.) no Sonoma. O OCLP restaura esses drivers no sistema.

---

## Passo 1: Acessar o OCLP no pendrive

O OCLP ja esta incluido na particao EFI do pendrive que voce criou.
Para acessa-lo, abra o **Terminal.app** no Mac (Aplicativos > Utilitarios > Terminal):

```bash
# Ver todos os discos e encontrar o pendrive USB
diskutil list

# Procure a particao EFI do seu USB (normalmente disk2s1 ou disk3s1)
# O USB aparece como "external, physical" e a EFI tem ~300 MB

# Montar a particao EFI
sudo diskutil mount /dev/disk2s1
```

> **Dica:** Se nao sabe qual disco e o USB, procure o que tem ~300MB (EFI) + ~14GB (macOS Installer)

Apos montar, o OCLP estara em:
```
/Volumes/EFI/OCLP/OpenCore-Patcher.pkg
```

---

## Passo 2: Instalar o OCLP

### Se o arquivo e .pkg (versao atual):

```bash
# Copiar para a area de trabalho
cp /Volumes/EFI/OCLP/OpenCore-Patcher.pkg ~/Desktop/

# Instalar clicando duas vezes no Finder
# OU via Terminal:
sudo installer -pkg ~/Desktop/OpenCore-Patcher.pkg -target /
```

Apos instalar, o OCLP aparece em **Aplicativos** como **OpenCore-Patcher.app**.

### Se o arquivo e .app.zip (versao mais antiga):

```bash
# Copiar e descompactar
cp /Volumes/EFI/OCLP/*.zip ~/Desktop/
cd ~/Desktop
unzip OpenCore-Patcher-GUI.app.zip

# Remover quarentena do macOS (senao nao abre)
sudo xattr -r -d com.apple.quarantine OpenCore-Patcher.app

# Abrir
open OpenCore-Patcher.app
```

---

## Passo 3: Aplicar Root Patches (WiFi, GPU, Bluetooth)

1. **Abrir o OCLP** — duplo clique no app
   - Se o macOS bloquear: va em **Preferencias do Sistema > Privacidade e Seguranca** e clique em **"Abrir Mesmo Assim"**

2. Na tela principal do OCLP, clique em:
   > **"Post-Install Root Patch"**

3. O OCLP **analisa o seu Mac** e mostra os patches disponiveis:
   - `Wifi: Modern Wireless` — restaura driver BCM4360
   - `Bluetooth: Legacy Bluetooth` — restaura Bluetooth
   - `Graphics: Legacy GCN` — restaura GPU AMD (MacBookPro11,5)
   - `Graphics: Intel Iris` — restaura iGPU (MacBookPro11,4 / 12,1)

4. Clique em **"Start Root Patching"**

5. O OCLP pede **senha de administrador** — digite e confirme

6. Aguarde o patching completar (2-5 minutos)

7. Quando terminar, clique em **"Reboot"**

---

## Passo 4: Sem internet? Faca em duas etapas

Se voce **nao tem cabo Ethernet** e o WiFi ainda nao funciona:

### Primeira passada (sem internet):
- O OCLP aplica patches de **WiFi e Bluetooth** (nao precisam de download extra)
- Reinicie o Mac
- **WiFi agora funciona!**

### Segunda passada (com internet via WiFi):
- Abra o OCLP novamente
- Clique em **"Post-Install Root Patch"** de novo
- Agora o OCLP baixa o **KDK (Kernel Debug Kit)** da Apple (~500MB)
- Isso e necessario para os patches de **GPU/aceleracao grafica**
- Aguarde e reinicie novamente

> **Nota:** Se tiver cabo Ethernet ou iPhone USB Tethering, tudo instala de uma vez.

---

## Passo 5: Verificar que tudo funciona

Apos reiniciar:

- **WiFi**: clique no icone WiFi na barra de menus, deve aparecer redes disponiveis
- **Bluetooth**: Preferencias > Bluetooth, deve estar ativo
- **GPU**: se a interface nao esta lenta/com artefatos, a aceleracao esta OK
- **Audio**: teste com um video ou musica

### Se o WiFi nao aparecer:
```bash
# No Terminal, verificar se o driver carregou:
kextstat | grep -i brcm

# Deve mostrar algo como:
# com.apple.iokit.IO80211FamilyLegacy
# com.apple.driver.AirPort.BrcmNIC-MFG
```

### Se a GPU nao tiver aceleracao:
```bash
# Verificar se MetallibSupportPkg foi instalado:
system_profiler SPDisplaysDataType | grep Metal

# Se mostrar "Metal Family: Supported", esta OK
```

---

## Informacoes importantes

### Root patches sao apagados a cada atualizacao do macOS!
Sempre que atualizar o macOS (ex: 14.1 → 14.2), **voce precisa rodar o OCLP novamente**
e aplicar os root patches de novo. O OCLP pode mostrar uma notificacao automatica
lembrando disso.

### FileVault deve estar DESATIVADO
O root patching nao funciona com FileVault ativado.
Desative em: Preferencias > Seguranca e Privacidade > FileVault > Desativar

### SIP ja esta configurado
O nosso OpenCore config ja desativa o SIP parcialmente (`csr-active-config=0x803`)
com as flags necessarias para o OCLP funcionar:
- `CSR_ALLOW_UNTRUSTED_KEXTS`
- `CSR_ALLOW_UNRESTRICTED_FS`
- `CSR_ALLOW_UNAUTHENTICATED_ROOT`

### boot-args ja incluidos
O nosso config tem `amfi_get_out_of_my_way=0x01` que e necessario para
os patches de GPU funcionarem sem problemas.

---

## Resumo rapido

| Etapa | Acao |
|-------|------|
| 1 | Montar EFI: `sudo diskutil mount /dev/disk2s1` |
| 2 | Copiar OCLP: `cp /Volumes/EFI/OCLP/*.pkg ~/Desktop/` |
| 3 | Instalar: duplo clique no .pkg |
| 4 | Abrir OCLP > "Post-Install Root Patch" > "Start Root Patching" |
| 5 | Digite a senha > aguarde > reinicie |
| 6 | (Sem internet?) Repita o passo 4 apos WiFi funcionar para patches de GPU |
