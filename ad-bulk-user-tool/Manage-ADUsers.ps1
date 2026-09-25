<#
.SYNOPSIS
    CSV listesinden Active Directory'de toplu kullanıcı açar veya devre dışı bırakır.

.DESCRIPTION
    Create modunda her satır için kullanıcı oluşturur, doğru OU'ya yerleştirir,
    rastgele bir ilk parola üretir ve ilk girişte parola değişikliğini zorunlu kılar.
    Disable modunda hesabı kapatır, açıklama alanına kapatılma tarihini yazar ve
    hesabı devre dışı hesaplar OU'suna taşır.

    Her işlem zaman damgasıyla logs klasöründeki tarihli bir dosyaya yazılır.
    -WhatIf ile çalıştırıldığında hiçbir değişiklik yapılmaz, yalnızca yapılacak
    işlemler listelenir.

.PARAMETER CsvPath
    Noktalı virgülle ayrılmış, UTF-8 kodlu CSV. Create için sütunlar:
    Ad;Soyad;KullaniciAdi;Departman;OU   Disable için yalnızca KullaniciAdi yeterlidir.

.PARAMETER Mode
    Create veya Disable.

.EXAMPLE
    .\Manage-ADUsers.ps1 -CsvPath .\ornek-kullanicilar.csv -Mode Create -WhatIf

.EXAMPLE
    .\Manage-ADUsers.ps1 -CsvPath .\ayrilanlar.csv -Mode Disable -DisabledOU "OU=Disabled Users,DC=lab,DC=local"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidateSet('Create', 'Disable')]
    [string]$Mode,

    [string]$UpnSuffix = 'lab.local',

    [string]$DisabledOU = 'OU=Disabled Users,DC=lab,DC=local',

    [string]$LogDir,

    [ValidateRange(12, 64)]
    [int]$PasswordLength = 14
)

Set-StrictMode -Version Latest

# Modül yalnızca cmdlet'ler yüklü değilse içe aktarılır (testlerde sahte cmdlet'ler kullanılabilsin diye).
if (-not (Get-Command -Name New-ADUser -ErrorAction SilentlyContinue)) {
    Import-Module ActiveDirectory -ErrorAction Stop
}

if (-not $LogDir) { $LogDir = Join-Path -Path $PSScriptRoot -ChildPath 'logs' }
if (-not (Test-Path -Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -WhatIf:$false | Out-Null }
$RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path -Path $LogDir -ChildPath "${Mode}_$RunStamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('BILGI', 'OK', 'UYARI', 'HATA')][string]$Level = 'BILGI'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    # -WhatIf modunda da log yazılsın diye ShouldProcess kapatılır.
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -WhatIf:$false
    $color = @{ BILGI = 'Gray'; OK = 'Green'; UYARI = 'Yellow'; HATA = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function New-RandomPassword {
    <# Kriptografik rastgele sayı üreteciyle, her karakter grubundan en az bir tane içeren parola üretir.
       Karıştırılabilen karakterler (I, l, 1, O, 0) kullanıcıya iletilirken hata olmasın diye çıkarılmıştır. #>
    param([int]$Length = 14)

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%&*?-_+=')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Modulo yanlılığını önlemek için sınırın üzerindeki değerler atılır (rejection sampling).
        $nextIndex = {
            param([int]$Max)
            $buffer = [byte[]]::new(4)
            $range = [uint64][uint32]::MaxValue + 1
            $limit = $range - ($range % $Max)
            do {
                $rng.GetBytes($buffer)
                $value = [uint64][BitConverter]::ToUInt32($buffer, 0)
            } while ($value -ge $limit)
            [int]($value % $Max)
        }

        $chars = [System.Collections.Generic.List[char]]::new()
        foreach ($set in $sets) { $chars.Add($set[(& $nextIndex $set.Length)]) }
        $all = -join $sets
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $nextIndex $all.Length)]) }

        # Fisher-Yates karıştırma: zorunlu karakterler hep başta kalmasın.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $nextIndex ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

# ---------------------------------------------------------------- CSV okuma ve doğrulama
$users = @(Import-Csv -Path $CsvPath -Delimiter ';' -Encoding UTF8)
if ($users.Count -eq 0) { Write-Log "CSV dosyası boş: $CsvPath" 'HATA'; exit 1 }

$required = if ($Mode -eq 'Create') { 'Ad', 'Soyad', 'KullaniciAdi', 'Departman', 'OU' } else { 'KullaniciAdi' }
$columns = $users[0].PSObject.Properties.Name
$missing = @($required | Where-Object { $_ -notin $columns })
if ($missing.Count -gt 0) {
    Write-Log ("CSV'de eksik sütun: {0}. Ayırıcının ';' olduğunu kontrol edin." -f ($missing -join ', ')) 'HATA'
    exit 1
}

Write-Log ("{0} modu başladı: {1} satır, dosya: {2}{3}" -f $Mode, $users.Count, $CsvPath,
    $(if ($WhatIfPreference) { ' (WhatIf: değişiklik yapılmayacak)' } else { '' }))

# ---------------------------------------------------------------- Ana döngü
$created = [System.Collections.Generic.List[object]]::new()
$okCount = 0; $errCount = 0

foreach ($u in $users) {
    $sam = "$($u.KullaniciAdi)".Trim()
    if (-not $sam) { Write-Log 'KullaniciAdi boş olan satır atlandı' 'UYARI'; continue }

    try {
        if ($Mode -eq 'Create') {
            if ($PSCmdlet.ShouldProcess("$sam ($($u.OU))", 'Kullanıcı oluştur')) {
                $plain = New-RandomPassword -Length $PasswordLength
                $sifre = ConvertTo-SecureString -String $plain -AsPlainText -Force
                $p = @{
                    Name                  = "$($u.Ad) $($u.Soyad)".Trim()
                    DisplayName           = "$($u.Ad) $($u.Soyad)".Trim()
                    GivenName             = $u.Ad
                    Surname               = $u.Soyad
                    SamAccountName        = $sam
                    UserPrincipalName     = "$sam@$UpnSuffix"
                    Department            = $u.Departman
                    Path                  = $u.OU
                    AccountPassword       = $sifre
                    ChangePasswordAtLogon = $true
                    Enabled               = $true
                }
                New-ADUser @p -ErrorAction Stop
                $created.Add([pscustomobject]@{
                    KullaniciAdi = $sam
                    UPN          = "$sam@$UpnSuffix"
                    AdSoyad      = $p.Name
                    IlkParola    = $plain
                })
                Write-Log "$Mode OK: $sam" 'OK'
                $okCount++
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($sam, "Devre dışı bırak ve '$DisabledOU' OU'suna taşı")) {
                $adUser = Get-ADUser -Identity $sam -ErrorAction Stop
                Disable-ADAccount -Identity $adUser -ErrorAction Stop
                Set-ADUser -Identity $adUser -Description ('Kapatıldı: {0:dd.MM.yyyy}' -f (Get-Date)) -ErrorAction Stop
                Move-ADObject -Identity $adUser -TargetPath $DisabledOU -ErrorAction Stop
                Write-Log "$Mode OK: $sam" 'OK'
                $okCount++
            }
        }
    }
    catch {
        Write-Log "$Mode HATA: $sam - $($_.Exception.Message)" 'HATA'
        $errCount++
    }
}

# ---------------------------------------------------------------- İlk parolalar ve özet
if ($created.Count -gt 0) {
    $pwFile = Join-Path -Path $LogDir -ChildPath "ilk-parolalar_$RunStamp.csv"
    $created | Export-Csv -Path $pwFile -Delimiter ';' -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Log "İlk parolalar yazıldı: $pwFile (düz metin içerir, kullanıcılara iletildikten sonra silin)" 'UYARI'
}

Write-Log ("{0} modu tamamlandı: {1} başarılı, {2} hatalı. Log: {3}" -f $Mode, $okCount, $errCount, $LogFile)
if ($errCount -gt 0) { exit 2 }
