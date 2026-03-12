# Setup Driver Otomatis Acer ANV16

Repo ini berisi script otomatis untuk:
- download driver dari Windows Update,
- install driver dari folder lokal,
- export driver store Windows ke folder `Drivers`.

Script utama:
- `install.bat` (launcher, meminta hak Administrator)
- `install.ps1` (logika utama install)

## Struktur Folder

```text
AcerDrivers/
  install.bat
  install.ps1
  Drivers/
    .gitkeep
    README.md
```

Catatan:
- Isi folder `Drivers` tidak di-push ke GitHub (dibatasi oleh `.gitignore`).
- Ini penting supaya repo tetap ringan dan tidak mengunggah file binary driver.

## Cara Pakai

1. Jalankan `install.bat` sebagai Administrator.
2. Script akan:
- cek update driver dari Windows Update,
- coba pasang Acer Care Center S,
- install file driver lokal (jika ada),
- export driver store ke `Drivers/_exported_from_system`.
3. Restart setelah selesai.

## Push ke GitHub

Jalankan perintah berikut dari folder `C:\AcerDrivers`:

```powershell
git init
git add .
git commit -m "chore: setup ANV16 auto driver installer"
git remote add origin https://github.com/Bangkah/setup-anv16.git
git branch -M main
git push -u origin main
```

Jika remote sudah pernah ditambahkan, pakai:

```powershell
git remote set-url origin https://github.com/Bangkah/setup-anv16.git
git push -u origin main
```

## Troubleshooting

- Error `Jalankan script sebagai Administrator.`
  Jalankan `install.bat` dengan hak admin.

- Tidak ada driver terpasang (`sukses=0`)
  Biasanya karena Windows Update tidak menemukan update baru dan folder `Drivers` kosong.

- Ingin install OEM Acer offline
  Taruh file installer Acer (`.zip`, `.inf`, `.exe`, `.msi`) ke folder `Drivers`, lalu jalankan ulang.
