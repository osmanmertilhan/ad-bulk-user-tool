# AD Toplu Kullanıcı Yönetim Scripti

CSV listesinden Active Directory'de toplu kullanıcı açan veya hesapları devre
dışı bırakan PowerShell scripti.

## Gereksinimler

- Windows PowerShell 5.1 veya PowerShell 7
- ActiveDirectory modülü (domain controller'da hazır gelir; istemcide RSAT ile kurulur)
- Kullanıcı açma/kapatma yetkisi olan bir hesap
- Devre dışı hesaplar için bir OU (varsayılan: `OU=Disabled Users,DC=lab,DC=local`)

## CSV formatı

Ayırıcı noktalı virgül (`;`), kodlama UTF-8 olmalı. Excel'de "CSV UTF-8" olarak kaydedin.

```
Ad;Soyad;KullaniciAdi;Departman;OU
Ayşe;Yılmaz;ayilmaz;Muhasebe;OU=Muhasebe,OU=Kullanicilar,DC=lab,DC=local
```

Devre dışı bırakma için yalnızca `KullaniciAdi` sütunu yeterli.

Klasörde iki örnek dosya var: `ornek-kullanicilar.csv` (4 kişi) ve
`test-kullanicilari-50.csv` (lab testleri için 50 kişi). CSV'deki OU'ların
AD'de önceden oluşturulmuş olması gerekiyor.

## Kullanım

```powershell
# Önce ne yapacağını gör (hiçbir değişiklik yapmaz)
.\Manage-ADUsers.ps1 -CsvPath .\ornek-kullanicilar.csv -Mode Create -WhatIf

# Kullanıcıları oluştur
.\Manage-ADUsers.ps1 -CsvPath .\ornek-kullanicilar.csv -Mode Create

# Hesapları kapat ve Disabled Users OU'suna taşı
.\Manage-ADUsers.ps1 -CsvPath .\ayrilanlar.csv -Mode Disable
```

İsteğe bağlı parametreler: `-UpnSuffix` (varsayılan `lab.local`),
`-DisabledOU`, `-LogDir` (varsayılan `.\logs`), `-PasswordLength` (varsayılan 14).

Script internetten indirildiyse çalıştırmadan önce engelini kaldırın:
`Unblock-File .\Manage-ADUsers.ps1`

## Ne yapıyor?

**Create:** Kullanıcıyı CSV'deki OU'ya açar, UPN'i `kullaniciadi@lab.local`
yapar, harf, rakam ve sembol içeren rastgele bir ilk parola verir ve ilk
girişte parola değiştirmeyi zorunlu tutar.

**Disable:** Hesabı kapatır, açıklama alanına `Kapatıldı: gg.aa.yyyy` yazar
ve hesabı devre dışı hesaplar OU'suna taşır.

Bir satırda hata olursa (ör. kullanıcı adı zaten var) hata loglanır ve
script sonraki satırla devam eder.

## Çıktılar

- `logs\Create_<tarih>.log` / `logs\Disable_<tarih>.log`: her işlemin zaman damgalı kaydı
- `logs\ilk-parolalar_<tarih>.csv`: yeni kullanıcıların ilk parolaları


Çıkış kodları: `0` sorunsuz, `1` CSV hatası, `2` bazı satırlarda hata var.
