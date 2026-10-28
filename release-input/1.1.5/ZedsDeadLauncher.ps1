param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'launcher.config.json')
)

$script:LauncherRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($env:ZEDSDEAD_LAUNCHER_ROOT) { $env:ZEDSDEAD_LAUNCHER_ROOT } else { (Get-Location).Path }
$script:LogPath = Join-Path $script:LauncherRoot 'launcher.log'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LauncherLog {
    param([string]$Message, [System.Exception]$Exception)
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        if ($null -ne $Exception) { $line += "`r`n$($Exception.ToString())" }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch { }
}

Write-LauncherLog 'Démarrage du launcher.'
trap {
    Write-LauncherLog 'Erreur non gérée.' $_.Exception
    Show-LauncherMessage $_.Exception.Message 'Erreur du launcher' 'Error'
    break
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZedTaskbarIdentity {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}
'@
[ZedTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('ZedsDead.Launcher') | Out-Null

function Show-LauncherMessage {
    param([string]$Message, [string]$Title = "ZED'S DEAD", [string]$Icon = 'Information')
    [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::$Icon
    ) | Out-Null
}

function Confirm-LauncherAction {
    param([string]$Message, [string]$Title = "ZED'S DEAD")
    $result = [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    return $result -eq [System.Windows.MessageBoxResult]::Yes
}

function Get-FullSafePath {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded)
}

function Get-Sha256Hash {
    param([string]$Path)
    $stream = [IO.File]::OpenRead((Get-FullSafePath $Path))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Test-ChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = (Get-FullSafePath $Parent).TrimEnd('\') + '\'
    $childFull = Get-FullSafePath $Child
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Open-AllowedUri {
    param([string]$UriText, [string[]]$AllowedSchemes)
    $uri = $null
    if (-not [Uri]::TryCreate($UriText, [UriKind]::Absolute, [ref]$uri)) {
        throw "Adresse invalide : $UriText"
    }
    if ($AllowedSchemes -notcontains $uri.Scheme.ToLowerInvariant()) {
        throw "Protocole non autorisé : $($uri.Scheme)"
    }
    Start-Process -FilePath $uri.AbsoluteUri | Out-Null
}

function Test-HttpsUri {
    param([string]$UriText)
    $uri = $null
    return [Uri]::TryCreate($UriText, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https'
}

function Start-ScumGame {
    param([object]$Server)
    $executablePath = Get-FullSafePath (Join-Path $script:GamePath ([string]$script:Config.game.requiredExecutable))
    if (-not (Test-ChildPath -Parent $script:GamePath -Child $executablePath) -or -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Exécutable SCUM introuvable : $executablePath"
    }
    $arguments = @()
    foreach ($argumentTemplate in $script:Config.game.launchArguments) {
        $arguments += ([string]$argumentTemplate).Replace('{host}', [string]$Server.host).Replace('{port}', [string]$Server.port)
    }
    Start-Process -FilePath $executablePath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $executablePath) | Out-Null
}

function Expand-VerifiedZip {
    param([string]$ArchivePath, [string]$Destination)
    $destinationFull = Get-FullSafePath $Destination
    New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryPath = Get-FullSafePath (Join-Path $destinationFull $entry.FullName)
            if (-not (Test-ChildPath -Parent $destinationFull -Child $entryPath)) {
                throw "Archive refusée : chemin sortant du dossier géré."
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $entryPath -Force | Out-Null
                continue
            }
            $entryFolder = Split-Path -Parent $entryPath
            New-Item -ItemType Directory -Path $entryFolder -Force | Out-Null
            $inputStream = $entry.Open()
            $outputStream = [IO.File]::Open($entryPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Show-LauncherMessage "Configuration introuvable : $ConfigPath" "Erreur" 'Error'
    exit 1
}

try {
    $script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Show-LauncherMessage "Configuration JSON invalide.`n$($_.Exception.Message)" "Erreur" 'Error'
    exit 1
}

function Test-ScumFolder {
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return $false }
    $required = [string]$script:Config.game.requiredExecutable
    return Test-Path -LiteralPath (Join-Path $Folder $required) -PathType Leaf
}

function Save-UserSettings {
    $settingsFolder = Split-Path -Parent $script:SettingsPath
    New-Item -ItemType Directory -Path $settingsFolder -Force | Out-Null
    @{
        scumPath = if ($script:GamePath) { Get-FullSafePath $script:GamePath } else { $null }
        saveMods = [bool]$script:SaveMods
    } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Select-ScumFolder {
    param([bool]$Required)
    while ($true) {
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = "Sélectionnez le dossier d'installation de SCUM (le dossier qui contient le sous-dossier SCUM)."
        $dialog.ShowNewFolderButton = $false
        if ($script:GamePath -and (Test-Path -LiteralPath $script:GamePath)) { $dialog.SelectedPath = $script:GamePath }
        $result = $dialog.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return -not $Required }
        if (Test-ScumFolder $dialog.SelectedPath) {
            $script:GamePath = Get-FullSafePath $dialog.SelectedPath
            Save-UserSettings
            return $true
        }
        Show-LauncherMessage "Le fichier '$($script:Config.game.requiredExecutable)' n'a pas été trouvé dans ce dossier." "Dossier SCUM invalide" 'Warning'
    }
}

function Show-ScumSetupWindow {
    $setupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZED'S DEAD — Configuration" Width="920" Height="560" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#080A0F" FontFamily="Segoe UI Variable Display">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#E74735"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="26,13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.86"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.68"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid>
        <Border Background="#94070A0F"/>
        <Border Width="650" Padding="42" CornerRadius="22" Background="#E712161F" BorderBrush="#55FFFFFF" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel Orientation="Horizontal">
                    <Border Width="58" Height="58" CornerRadius="14" Background="#E74735">
                        <TextBlock Text="Z/D" Foreground="White" FontSize="21" FontWeight="Black" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="16,5,0,0">
                        <TextBlock Text="ZED'S DEAD" Foreground="White" FontSize="23" FontWeight="Black"/>
                        <TextBlock Text="SCUM COMMUNITY LAUNCHER" Foreground="#94A1B5" FontSize="11" FontWeight="Bold"/>
                    </StackPanel>
                </StackPanel>
                <StackPanel Grid.Row="1" VerticalAlignment="Center">
                    <TextBlock Text="LOCALISER SCUM" Foreground="#FF705E" FontSize="13" FontWeight="Bold"/>
                    <TextBlock Text="Avant de survivre, trouvons le jeu." Foreground="White" FontSize="31" FontWeight="Black" Margin="0,7,0,12"/>
                    <TextBlock Text="Sélectionnez le dossier principal de SCUM. Le chemin sera vérifié puis conservé uniquement sur cet ordinateur." Foreground="#B4BDCA" FontSize="15" TextWrapping="Wrap" LineHeight="23"/>
                    <Border Margin="0,24,0,0" Padding="16,12" CornerRadius="8" Background="#801F2632">
                        <TextBlock Name="SelectedPathText" Text="Aucun dossier sélectionné" Foreground="#D8DEE8" TextTrimming="CharacterEllipsis"/>
                    </Border>
                </StackPanel>
                <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button Name="CancelButton" Content="PLUS TARD" Background="#303744" Margin="0,0,10,0"/>
                    <Button Name="UseSuggestedButton" Content="UTILISER CE DOSSIER" Margin="0,0,10,0"/>
                    <Button Name="BrowseButton" Content="CHOISIR LE DOSSIER SCUM"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@
    $setupReader = [Xml.XmlNodeReader]::new([xml]$setupXaml)
    $setupWindow = [System.Windows.Markup.XamlReader]::Load($setupReader)
    $setupBackgroundPath = Join-Path $script:LauncherRoot 'zeds-dead-background.png'
    if (Test-Path -LiteralPath $setupBackgroundPath -PathType Leaf) {
        $setupImage = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$setupBackgroundPath)
        $setupBrush = [System.Windows.Media.ImageBrush]::new($setupImage)
        $setupBrush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $setupWindow.Background = $setupBrush
    }
    $selectedPathText = $setupWindow.FindName('SelectedPathText')
    $useSuggestedButton = $setupWindow.FindName('UseSuggestedButton')
    if (Test-ScumFolder $script:GamePath) {
        $selectedPathText.Text = $script:GamePath
        $useSuggestedButton.Visibility = [Windows.Visibility]::Visible
    }
    else {
        $useSuggestedButton.Visibility = [Windows.Visibility]::Collapsed
    }
    $setupWindow.FindName('CancelButton').Add_Click({ $setupWindow.DialogResult = $false; $setupWindow.Close() })
    $useSuggestedButton.Add_Click({
        if (Test-ScumFolder $script:GamePath) {
            Save-UserSettings
            $setupWindow.DialogResult = $true
            $setupWindow.Close()
        }
    })
    $setupWindow.FindName('BrowseButton').Add_Click({
        if (Select-ScumFolder -Required $false) {
            $setupWindow.FindName('SelectedPathText').Text = $script:GamePath
            $setupWindow.DialogResult = $true
            $setupWindow.Close()
        }
    })
    return [bool]$setupWindow.ShowDialog()
}

$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'ZedsDeadLauncher\settings.json'
$script:GamePath = $null
$script:SaveMods = [bool]$script:Config.mods.keepInstalledByDefault
$hasSavedSettings = Test-Path -LiteralPath $script:SettingsPath -PathType Leaf
$savedPathIsValid = $false
if ($hasSavedSettings) {
    try {
        $savedSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:GamePath = $savedSettings.scumPath
        if ($savedSettings.PSObject.Properties.Name -contains 'saveMods') { $script:SaveMods = [bool]$savedSettings.saveMods }
    }
    catch { $script:GamePath = $null }
    $savedPathIsValid = Test-ScumFolder $script:GamePath
}
if (-not (Test-ScumFolder $script:GamePath)) {
    $programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    $defaultGamePath = ([string]$script:Config.game.defaultInstallPath).Replace('{programFilesX86}', $programFilesX86)
    if (Test-ScumFolder $defaultGamePath) { $script:GamePath = Get-FullSafePath $defaultGamePath }
}
if (-not $savedPathIsValid) {
    if (-not (Show-ScumSetupWindow)) { exit 0 }
}

$script:ModCacheRoot = Get-FullSafePath (([string]$script:Config.mods.cacheDirectory).Replace('{localAppData}', $env:LOCALAPPDATA))
$script:ActiveModsRoot = Get-FullSafePath (([string]$script:Config.mods.activeDirectory).Replace('{scumPath}', $script:GamePath))
$script:InactiveModsRoot = Get-FullSafePath (([string]$script:Config.mods.inactiveDirectory).Replace('{scumPath}', $script:GamePath))
foreach ($legacyRoot in @($script:ActiveModsRoot, $script:InactiveModsRoot)) {
    $legacyManifest = Join-Path $legacyRoot '.zedsdead-active-files.json'
    if (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
        New-Item -ItemType Directory -Path $script:ModCacheRoot -Force | Out-Null
        Move-Item -LiteralPath $legacyManifest -Destination (Join-Path $script:ModCacheRoot '.zedsdead-active-files.json') -Force
    }
}
$driveRoot = [IO.Path]::GetPathRoot($script:ActiveModsRoot).TrimEnd('\')
if ($script:ActiveModsRoot.TrimEnd('\') -eq $driveRoot) {
    Show-LauncherMessage "Le dossier de mods ne peut pas être la racine d'un disque." "Configuration refusée" 'Error'
    exit 1
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ZED'S DEAD" Height="780" Width="1280" MinHeight="700" MinWidth="1100"
        WindowStartupLocation="CenterScreen" Background="#090B10" FontFamily="Segoe UI Variable Display" UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="Panel" Color="#E310141C"/>
        <SolidColorBrush x:Key="PanelSoft" Color="#ED171C26"/>
        <SolidColorBrush x:Key="Accent" Color="#E74735"/>
        <SolidColorBrush x:Key="AccentSoft" Color="#FF725E"/>
        <SolidColorBrush x:Key="Text" Color="#F5F7FA"/>
        <SolidColorBrush x:Key="Muted" Color="#9AA5B5"/>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#D52A313E"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.84"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.66"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
        </Style>
        <Style TargetType="ListViewItem">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="8"/>
            <Setter Property="Margin" Value="0,2"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        </Style>
        <Style TargetType="GridViewColumnHeader">
            <Setter Property="Background" Value="#202631"/>
            <Setter Property="Foreground" Value="#9DA8B8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#8F9AAC"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="18,11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Foreground" Value="White"/>
                    <Setter Property="Background" Value="#E74735"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="205"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.ColumnSpan="2" Background="#9A07090D"/>

        <Border Grid.Column="0" Background="#E0080B10" BorderBrush="#352F3744" BorderThickness="0,0,1,0">
            <Grid Margin="18">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel>
                    <Border Width="60" Height="60" CornerRadius="15" HorizontalAlignment="Left">
                        <Border.Background>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                <GradientStop Color="#FF735F" Offset="0"/>
                                <GradientStop Color="#B4142A" Offset="1"/>
                            </LinearGradientBrush>
                        </Border.Background>
                        <TextBlock Text="Z/D" FontSize="21" FontWeight="Black" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                    </Border>
                    <TextBlock Text="ZED'S DEAD" Margin="0,14,0,0" FontSize="23" FontWeight="Black"/>
                    <TextBlock Name="CommunityLabel" Text="SCUM COMMUNITY" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="Bold"/>
                </StackPanel>
                <StackPanel Grid.Row="1" VerticalAlignment="Center">
                    <Button Name="ServersNavButton" Content="SERVEURS" HorizontalContentAlignment="Left" Background="#E54135"/>
                    <Button Name="DiscordButton" Content="DISCORD" HorizontalContentAlignment="Left"/>
                    <Button Name="ScumPathButton" Content="DOSSIER SCUM" HorizontalContentAlignment="Left"/>
                    <Button Name="OpenModsButton" Content="DOSSIER MODS" HorizontalContentAlignment="Left"/>
                </StackPanel>
                <StackPanel Grid.Row="2">
                    <TextBlock Name="LanguageLabel" Text="LANGUE" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="Bold" Margin="4,0,0,6"/>
                    <ComboBox Name="LanguageCombo" SelectedIndex="0" Padding="8">
                        <ComboBoxItem Tag="fr" Content="Français"/>
                        <ComboBoxItem Tag="en" Content="English"/>
                    </ComboBox>
                    <TextBlock Name="VersionText" Text="v0.1.0" Foreground="{StaticResource Muted}" Margin="4,12,0,0"/>
                </StackPanel>
            </Grid>
        </Border>

        <Grid Grid.Column="1" Margin="24">
            <Grid.RowDefinitions>
                <RowDefinition Height="205"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border CornerRadius="18" Padding="30" BorderBrush="#42FFFFFF" BorderThickness="1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#E42D1016" Offset="0"/>
                        <GradientStop Color="#D6171C26" Offset="0.58"/>
                        <GradientStop Color="#D20E252C" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Name="HeroKicker" Text="WELCOME, SURVIVOR" Foreground="#FF725E" FontSize="13" FontWeight="Bold"/>
                        <TextBlock Name="HeroTitle" Text="THE DEAD DON'T WAIT." FontSize="38" FontWeight="Black" Margin="0,4,0,8"/>
                        <TextBlock Name="HeroSubtitle" Text="Choose your server, sync managed mods, then join." Foreground="{StaticResource Muted}" FontSize="15"/>
                    </StackPanel>
                    <Border Grid.Column="1" Width="128" Height="128" CornerRadius="22" Background="#B411141B" BorderBrush="#E74735" BorderThickness="2">
                        <Grid>
                            <TextBlock Text="Z" FontSize="70" FontWeight="Black" Foreground="#FFEDE9" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-10,20,0"/>
                            <TextBlock Text="D" FontSize="70" FontWeight="Black" Foreground="#E74735" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="24,18,0,0"/>
                        </Grid>
                    </Border>
                </Grid>
            </Border>

            <TabControl Grid.Row="1" Name="MainTabs" Margin="0,18,0,14" Background="Transparent" BorderThickness="0">
                <TabItem Name="ServersTab" Header="SERVEURS">
                    <Grid Margin="0,14,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <ListView Name="ServersList" Background="{StaticResource Panel}" BorderThickness="0">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="SERVEUR" Width="290" DisplayMemberBinding="{Binding Name}"/>
                                    <GridViewColumn Header="MODE" Width="130" DisplayMemberBinding="{Binding Mode}"/>
                                    <GridViewColumn Header="ADRESSE" Width="160" DisplayMemberBinding="{Binding Address}"/>
                                    <GridViewColumn Header="STATUT" Width="120" DisplayMemberBinding="{Binding Status}"/>
                                    <GridViewColumn Header="JOUEURS" Width="90" DisplayMemberBinding="{Binding Players}"/>
                                </GridView>
                            </ListView.View>
                        </ListView>
                        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
                            <Button Name="RefreshServersButton" Content="ACTUALISER"/>
                            <Button Name="CopyAddressButton" Content="COPIER L'ADRESSE"/>
                            <Button Name="ConnectButton" Content="REJOINDRE" Background="#E54135" Padding="28,10"/>
                        </StackPanel>
                    </Grid>
                </TabItem>
                <TabItem Name="ModsTab" Header="MODS GÉRÉS">
                    <Grid Margin="0,14,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <ListView Name="ModsList" Background="{StaticResource Panel}" BorderThickness="0">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="MOD" Width="340" DisplayMemberBinding="{Binding Name}"/>
                                    <GridViewColumn Header="VERSION" Width="150" DisplayMemberBinding="{Binding Version}"/>
                                    <GridViewColumn Header="STATUT" Width="200" DisplayMemberBinding="{Binding Status}"/>
                                </GridView>
                            </ListView.View>
                        </ListView>
                        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
                            <Button Name="RemoveModButton" Content="SUPPRIMER"/>
                            <Button Name="InstallModButton" Content="INSTALLER / METTRE À JOUR" Background="#E54135"/>
                        </StackPanel>
                    </Grid>
                </TabItem>
            </TabControl>

            <Border Grid.Row="2" Background="{StaticResource PanelSoft}" CornerRadius="12" Padding="16,12">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Name="StatusText" Text="Prêt." FontWeight="SemiBold"/>
                        <TextBlock Name="UpdateText" Text="Mise à jour non vérifiée" Foreground="{StaticResource Muted}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <CheckBox Name="KeepModsCheck" Content="Conserver les mods" Foreground="White" VerticalAlignment="Center" Margin="0,0,14,0"/>
                        <Button Name="CheckUpdateButton" Content="VÉRIFIER LA VERSION"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
'@

$launcherXamlPath = Join-Path $script:LauncherRoot 'Launcher.xaml'
$launcherXaml = Get-Content -LiteralPath $launcherXamlPath -Raw -Encoding UTF8
$reader = [Xml.XmlNodeReader]::new([xml]$launcherXaml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

function Find-Control([string]$Name) {
    return $script:Window.FindName($Name)
}

$script:Controls = @{}
@(
    'CommunityLabel','ServersNavButton','DiscordButton','VoteButton','VoteButton2','ScumPathButton','OpenModsButton','LanguageLabel','FrenchButton','EnglishButton',
    'VersionText','HeroKicker','HeroTitle','HeroSubtitle','MainTabs','ServersTab','ModsTab','ServersList','ModsList',
    'RefreshServersButton','CopyAddressButton','ConnectButton','RemoveModButton','InstallModButton','StatusText',
    'UpdateText','KeepModsCheck','CheckUpdateButton','AskBeforeLaunchCheck','MusicButton','MinimizeButton','CloseButton','TitleBar',
    'HeaderLogoImage','HeroLogoImage','MusicPlayer'
) | ForEach-Object { $script:Controls[$_] = Find-Control $_ }

$script:Translations = @{
    fr = @{
        CommunityLabel='COMMUNAUTÉ SCUM'; ServersNavButton='SERVEURS'; DiscordButton='DISCORD';
        ScumPathButton='DOSSIER SCUM'; OpenModsButton='DOSSIER MODS'; LanguageLabel='LANGUE'; HeroKicker='RESTEZ EN VIE. RESTEZ HUMAIN.';
        HeroTitle="MODS ZED'S DEAD"; HeroSubtitle='Le dossier mods devient ~mods au lancement et redevient mods à la fermeture.';
        ServersTab='SERVEURS'; ModsTab='MODS GÉRÉS'; RefreshServersButton='ACTUALISER'; CopyAddressButton="COPIER L'ADRESSE IP";
        ConnectButton='REJOINDRE'; RemoveModButton='DELETE MODS'; InstallModButton='INSTALLER / METTRE À JOUR';
        KeepModsCheck='SAVE MODS'; CheckUpdateButton='VÉRIFIER LA VERSION'; Ready='Prêt.'; Unknown='Non vérifié';
        Installed='Téléchargé'; NotInstalled='Non téléchargé'; NotConfigured='Non configuré'
    }
    en = @{
        CommunityLabel='SCUM COMMUNITY'; ServersNavButton='SERVERS'; DiscordButton='DISCORD';
        ScumPathButton='SCUM FOLDER'; OpenModsButton='MODS FOLDER'; LanguageLabel='LANGUAGE'; HeroKicker='STAY ALIVE. STAY HUMAN.';
        HeroTitle="ZED'S DEAD MODS"; HeroSubtitle='The mods folder becomes ~mods when joining and returns to mods when the launcher closes.';
        ServersTab='SERVERS'; ModsTab='MANAGED MODS'; RefreshServersButton='REFRESH'; CopyAddressButton='COPY ADDRESS';
        ConnectButton='JOIN'; RemoveModButton='DELETE MODS'; InstallModButton='INSTALL / UPDATE';
        KeepModsCheck='SAVE MODS'; CheckUpdateButton='CHECK VERSION'; Ready='Ready.'; Unknown='Not checked';
        Installed='Downloaded'; NotInstalled='Not downloaded'; NotConfigured='Not configured'
    }
}

$script:Language = if ($script:Config.launcher.defaultLanguage -eq 'en') { 'en' } else { 'fr' }
$script:ServerStatus = @{}

function Set-Status([string]$Message) {
    $script:Controls.StatusText.Text = $Message
}

function Update-Language {
    $dictionary = $script:Translations[$script:Language]
    foreach ($name in $dictionary.Keys) {
        if ($script:Controls.ContainsKey($name)) {
            if ($name -like '*Tab') { $script:Controls[$name].Header = $dictionary[$name] }
            elseif ($script:Controls[$name] -is [System.Windows.Controls.TextBlock]) { $script:Controls[$name].Text = $dictionary[$name] }
            else { $script:Controls[$name].Content = $dictionary[$name] }
        }
    }
    Set-Status $dictionary.Ready
    if ($script:Language -eq 'fr') {
        $script:Controls.FrenchButton.Background = [Windows.Media.Brushes]::DarkOrange
        $script:Controls.EnglishButton.Background = [Windows.Media.Brushes]::Transparent
    }
    else {
        $script:Controls.FrenchButton.Background = [Windows.Media.Brushes]::Transparent
        $script:Controls.EnglishButton.Background = [Windows.Media.Brushes]::DarkOrange
    }
    Refresh-ServerRows
    Refresh-ModRows
}

function Refresh-ServerRows {
    $rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($server in $script:Config.servers) {
        $status = $script:Translations[$script:Language].Unknown
        $players = '—'
        if ($script:ServerStatus.ContainsKey($server.id)) {
            $status = $script:ServerStatus[$server.id].Status
            $players = $script:ServerStatus[$server.id].Players
        }
        $rows.Add([pscustomobject]@{
            Id=$server.id; Name=$server.name; Mode=$server.mode; Address="$($server.host):$($server.port)"; Status=$status; Players=$players
        })
    }
    $script:Controls.ServersList.ItemsSource = $rows
    if ($rows.Count -gt 0) { $script:Controls.ServersList.SelectedIndex = 0 }
}

function Get-ModTarget([object]$Package) {
    if ($Package.id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$') { throw "Identifiant de mod invalide : $($Package.id)" }
    $target = Join-Path $script:ModCacheRoot $Package.id
    if (-not (Test-ChildPath -Parent $script:ModCacheRoot -Child $target)) { throw 'Chemin de mod refusé.' }
    return $target
}

function Test-ManagedPackageCached([object]$Package) {
    $target = Get-ModTarget $Package
    $marker = Join-Path $target '.zedsdead-managed-mod'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    if ((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() -ne "$($Package.id)|$($Package.version)") { return $false }
    $packageKind = if ($Package.PSObject.Properties.Name -contains 'kind') { [string]$Package.kind } else { 'zip' }
    if ($packageKind -eq 'pak') {
        $fileName = [string]$Package.fileName
        $pakPath = Join-Path $target $fileName
        if (-not (Test-Path -LiteralPath $pakPath -PathType Leaf)) { return $false }
        return (Get-Sha256Hash $pakPath) -eq ([string]$Package.sha256).ToUpperInvariant()
    }
    return $true
}

function Test-ModManifest([object]$Manifest) {
    if ($null -eq $Manifest -or $Manifest.schemaVersion -ne 1) { throw 'Version de liste de mods non prise en charge.' }
    $packages = @($Manifest.packages)
    if ($packages.Count -lt 1 -or $packages.Count -gt 20) { throw 'Nombre de mods invalide.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fileNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $packages) {
        $id = [string]$package.id
        $fileName = [string]$package.fileName
        $url = [string]$package.url
        if ($id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$' -or -not $ids.Add($id)) { throw 'Identifiant de mod invalide ou en double.' }
        if ([string]::IsNullOrWhiteSpace([string]$package.name) -or [string]::IsNullOrWhiteSpace([string]$package.version)) { throw "Nom ou version de mod absent : $id" }
        if ([string]$package.kind -ne 'pak') { throw "Type de mod invalide : $id" }
        if ($fileName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*\.pak$' -or -not $fileNames.Add($fileName)) { throw 'Nom de PAK invalide ou en double.' }
        $expectedPrefix = 'https://github.com/lacrampe09/zeddead/releases/download/'
        if (-not $url.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not $url.EndsWith('/' + $fileName, [StringComparison]::OrdinalIgnoreCase)) { throw "Adresse de téléchargement non autorisée : $id" }
        if ([string]$package.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Empreinte SHA-256 invalide : $id" }
    }
    return $packages
}

function Sync-ModManifest {
    $manifestUrl = [string]$script:Config.mods.manifestUrl
    $expectedUrl = 'https://raw.githubusercontent.com/lacrampe09/zeddead/main/mods.json'
    if ($manifestUrl -ne $expectedUrl) { throw 'Adresse de liste de mods non autorisée.' }
    New-Item -ItemType Directory -Path $script:ModCacheRoot -Force | Out-Null
    $cachePath = Join-Path $script:ModCacheRoot 'mods-manifest.json'
    $previousPackages = @($script:Config.mods.packages)
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try { $previousPackages = @(Test-ModManifest (Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json)) }
        catch { }
    }
    $manifest = $null
    try {
        $response = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control'='no-cache' }
        if ($response.RawContentLength -gt 1048576) { throw 'Liste de mods trop volumineuse.' }
        $manifest = $response.Content | ConvertFrom-Json
        $packages = @(Test-ModManifest $manifest)
        [IO.File]::WriteAllText($cachePath, ($response.Content), [Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-LauncherLog "Liste GitHub indisponible : $($_.Exception.Message)"
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            try {
                $manifest = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $packages = @(Test-ModManifest $manifest)
            }
            catch { $packages = @($script:Config.mods.packages) }
        }
        else { $packages = @($script:Config.mods.packages) }
    }
    $previous = @($previousPackages | ForEach-Object { "$($_.id)|$($_.version)|$($_.fileName)|$($_.sha256)" }) -join ';'
    $current = @($packages | ForEach-Object { "$($_.id)|$($_.version)|$($_.fileName)|$($_.sha256)" }) -join ';'
    if ($current -ne $previous) {
        Set-Content -LiteralPath (Join-Path $script:ModCacheRoot '.activation-required') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding UTF8
    }
    $script:Config.mods.packages = $packages
    Refresh-ModRows
}

function Refresh-ModRows {
    $rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($package in $script:Config.mods.packages) {
        $target = Get-ModTarget $package
        $configured = (Test-HttpsUri $package.url) -and ($package.sha256 -match '^[A-Fa-f0-9]{64}$')
        $status = if (-not $configured) { $script:Translations[$script:Language].NotConfigured }
                  elseif (Test-ManagedPackageCached $package) { $script:Translations[$script:Language].Installed }
                  else { $script:Translations[$script:Language].NotInstalled }
        $rows.Add([pscustomobject]@{ Id=$package.id; Name=$package.name; Version=$package.version; Status=$status })
    }
    $script:Controls.ModsList.ItemsSource = $rows
    if ($rows.Count -gt 0) { $script:Controls.ModsList.SelectedIndex = 0 }
}

function Get-SelectedServer {
    $row = $script:Controls.ServersList.SelectedItem
    if ($null -eq $row) { return $null }
    return $script:Config.servers | Where-Object id -eq $row.Id | Select-Object -First 1
}

function Get-SelectedPackage {
    $row = $script:Controls.ModsList.SelectedItem
    if ($null -eq $row) { return $null }
    return $script:Config.mods.packages | Where-Object id -eq $row.Id | Select-Object -First 1
}

function Remove-ManagedPackage {
    param([object]$Package, [bool]$Ask = $true)
    $target = Get-ModTarget $Package
    $marker = Join-Path $target '.zedsdead-managed-mod'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return }
    if ($Ask -and -not (Confirm-LauncherAction "Supprimer le mod géré '$($Package.name)' ?")) { return }
    Remove-Item -LiteralPath $target -Recurse -Force
}

function Install-ManagedPackage {
    param([object]$Package, [bool]$ConfirmReplace = $true)
    $temporaryArchive = $null
    try {
        if (-not (Test-HttpsUri $Package.url)) { throw 'URL HTTPS du mod non configurée.' }
        if ($Package.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Empreinte SHA-256 du mod non configurée.' }
        $target = Get-ModTarget $Package
        if ($ConfirmReplace -and (Test-Path -LiteralPath $target) -and -not (Confirm-LauncherAction "Remplacer la version téléchargée de '$($Package.name)' ?")) { return $false }
        Set-Status "Téléchargement de $($Package.name)…"
        $packageKind = if ($Package.PSObject.Properties.Name -contains 'kind') { [string]$Package.kind } else { 'zip' }
        $temporaryExtension = if ($packageKind -eq 'pak') { '.pak' } else { '.zip' }
        $temporaryArchive = Join-Path ([IO.Path]::GetTempPath()) ("zedsdead-" + [guid]::NewGuid().ToString('N') + $temporaryExtension)
        Invoke-WebRequest -Uri $Package.url -OutFile $temporaryArchive -UseBasicParsing -TimeoutSec 600
        $actualHash = Get-Sha256Hash $temporaryArchive
        if ($actualHash -ne $Package.sha256.ToUpperInvariant()) { throw 'Empreinte SHA-256 incorrecte. Installation annulée.' }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        if ($packageKind -eq 'pak') {
            $fileName = [string]$Package.fileName
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or [IO.Path]::GetExtension($fileName) -ne '.pak') { throw 'Nom de fichier PAK invalide.' }
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -LiteralPath $temporaryArchive -Destination (Join-Path $target $fileName) -Force
        }
        elseif ($packageKind -eq 'zip') {
            Expand-VerifiedZip -ArchivePath $temporaryArchive -Destination $target
        }
        else { throw "Type de paquet non pris en charge : $packageKind" }
        Set-Content -LiteralPath (Join-Path $target '.zedsdead-managed-mod') -Value "$($Package.id)|$($Package.version)" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ModCacheRoot '.activation-required') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding UTF8
        return $true
    }
    finally {
        if ($temporaryArchive -and (Test-Path -LiteralPath $temporaryArchive)) { Remove-Item -LiteralPath $temporaryArchive -Force }
    }
}

function Ensure-ModCache {
    New-Item -ItemType Directory -Path $script:ModCacheRoot -Force | Out-Null
    foreach ($package in $script:Config.mods.packages) {
        $target = Get-ModTarget $package
        if (-not (Test-ManagedPackageCached $package)) {
            Install-ManagedPackage -Package $package -ConfirmReplace $false | Out-Null
        }
    }
    Set-Content -LiteralPath (Join-Path $script:ModCacheRoot '.initialized') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding UTF8
    Refresh-ModRows
}

function Remove-PreviouslyActivatedFiles {
    param([string]$Root = $script:ActiveModsRoot)
    $manifestPath = Join-Path $script:ModCacheRoot '.zedsdead-active-files.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try { $relativeFiles = @(Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { $relativeFiles = @() }
    foreach ($relativeFile in $relativeFiles) {
        $target = Get-FullSafePath (Join-Path $Root ([string]$relativeFile))
        if ((Test-ChildPath -Parent $Root -Child $target) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
}

function Remove-AllManagedMods {
    foreach ($root in @($script:ActiveModsRoot, $script:InactiveModsRoot)) {
        if (Test-Path -LiteralPath (Join-Path $script:ModCacheRoot '.zedsdead-active-files.json') -PathType Leaf) {
            Remove-PreviouslyActivatedFiles -Root $root
            Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0 } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if (@(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $root -Force
            }
        }
    }
    foreach ($package in $script:Config.mods.packages) { Remove-ManagedPackage -Package $package -Ask $false }
    Remove-Item -LiteralPath (Join-Path $script:ModCacheRoot '.initialized') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $script:ModCacheRoot '.activation-required') -Force -ErrorAction SilentlyContinue
    Refresh-ModRows
}

function Activate-ManagedMods {
    Ensure-ModCache
    $activationRequiredPath = Join-Path $script:ModCacheRoot '.activation-required'
    $activationRequired = Test-Path -LiteralPath $activationRequiredPath -PathType Leaf
    $inactiveManifest = Join-Path $script:ModCacheRoot '.zedsdead-active-files.json'
    $activeExists = Test-Path -LiteralPath $script:ActiveModsRoot -PathType Container
    $inactiveExists = Test-Path -LiteralPath $script:InactiveModsRoot -PathType Container
    if ($activeExists -and $inactiveExists) {
        throw "Les dossiers mods et ~mods existent en même temps. Fermez SCUM puis gardez un seul des deux dossiers."
    }
    if (-not $activeExists -and $inactiveExists) {
        Rename-Item -LiteralPath $script:InactiveModsRoot -NewName ([IO.Path]::GetFileName($script:ActiveModsRoot))
        $activeExists = $true
        if (-not $activationRequired -and (Test-Path -LiteralPath $inactiveManifest -PathType Leaf)) { return }
    }
    $activeManifest = Join-Path $script:ModCacheRoot '.zedsdead-active-files.json'
    if ($activeExists -and (Test-Path -LiteralPath $activeManifest -PathType Leaf) -and -not $activationRequired) {
        return
    }
    New-Item -ItemType Directory -Path $script:ActiveModsRoot -Force | Out-Null
    Remove-PreviouslyActivatedFiles
    $activatedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $script:Config.mods.packages) {
        $sourceRoot = Get-ModTarget $package
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot '.zedsdead-managed-mod') -PathType Leaf)) { throw "Mod non téléchargé : $($package.name)" }
        foreach ($sourceFile in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
            if ($sourceFile.Name -eq '.zedsdead-managed-mod') { continue }
            $relativePath = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
            if (-not $activatedFiles.Add($relativePath)) { throw "Deux mods utilisent le même fichier : $relativePath" }
            $destinationFile = Get-FullSafePath (Join-Path $script:ActiveModsRoot $relativePath)
            if (-not (Test-ChildPath -Parent $script:ActiveModsRoot -Child $destinationFile)) { throw 'Destination de mod refusée.' }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destinationFile) -Force | Out-Null
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile -Force
        }
    }
    $manifestPath = Join-Path $script:ModCacheRoot '.zedsdead-active-files.json'
    ConvertTo-Json -InputObject @($activatedFiles) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Remove-Item -LiteralPath $activationRequiredPath -Force -ErrorAction SilentlyContinue
}

function Deactivate-ManagedMods {
    if (-not (Test-Path -LiteralPath $script:ActiveModsRoot -PathType Container)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $script:ModCacheRoot '.zedsdead-active-files.json') -PathType Leaf)) { return }
    if (Test-Path -LiteralPath $script:InactiveModsRoot) { throw "Le dossier inactif existe déjà : $script:InactiveModsRoot" }
    Rename-Item -LiteralPath $script:ActiveModsRoot -NewName ([IO.Path]::GetFileName($script:InactiveModsRoot))
}

function Install-LauncherUpdate {
    param([object]$Manifest)
    $temporaryPackage = $null
    try {
        if (-not (Test-HttpsUri ([string]$Manifest.downloadUrl))) { throw 'URL HTTPS du paquet de mise à jour invalide.' }
        if ([string]$Manifest.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Empreinte SHA-256 de mise à jour invalide.' }

        $stagingBase = Join-Path $env:LOCALAPPDATA 'ZedsDeadLauncher\staged-updates'
        $stagingPath = Join-Path $stagingBase ("v" + [string]$Manifest.version)
        if (-not (Test-ChildPath -Parent $stagingBase -Child $stagingPath)) { throw 'Dossier temporaire de mise à jour refusé.' }

        Set-Status "Téléchargement de la version $($Manifest.version)…"
        $temporaryPackage = Join-Path ([IO.Path]::GetTempPath()) ("zedsdead-launcher-" + [guid]::NewGuid().ToString('N') + '.zip')
        Invoke-WebRequest -Uri $Manifest.downloadUrl -OutFile $temporaryPackage -UseBasicParsing -TimeoutSec 120
        $actualHash = Get-Sha256Hash $temporaryPackage
        if ($actualHash -ne ([string]$Manifest.sha256).ToUpperInvariant()) { throw 'Empreinte de mise à jour incorrecte. Installation annulée.' }

        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
        Expand-VerifiedZip -ArchivePath $temporaryPackage -Destination $stagingPath
        foreach ($requiredFile in @('ZedsDeadLauncher.ps1','Launcher.xaml','launcher.config.json','Apply-LauncherUpdate.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $stagingPath $requiredFile) -PathType Leaf)) {
                throw "Paquet incomplet : $requiredFile est absent."
            }
        }

        $updaterPath = Join-Path $script:LauncherRoot 'Apply-LauncherUpdate.ps1'
        if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) { throw 'Programme de mise à jour local introuvable.' }
        $arguments = @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$updaterPath`"",
            '-StagingPath',"`"$stagingPath`"",'-TargetPath',"`"$script:LauncherRoot`"",'-LauncherPid',"$PID"
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        $script:Window.Close()
    }
    finally {
        if ($temporaryPackage -and (Test-Path -LiteralPath $temporaryPackage)) { Remove-Item -LiteralPath $temporaryPackage -Force }
    }
}

function Check-LauncherUpdate {
    param([bool]$Interactive)
    try {
        $manifestUrl = [string]$script:Config.launcher.updateManifestUrl
        if (-not (Test-HttpsUri $manifestUrl)) { throw 'Manifeste de mise à jour non configuré.' }
        $manifest = Invoke-RestMethod -Uri $manifestUrl -Method Get -TimeoutSec 8
        $current = [Version]$script:Config.launcher.version
        $latest = [Version]([string]$manifest.version).TrimStart('v','V')
        if ($latest -le $current) {
            $script:Controls.UpdateText.Text = "Version à jour : $current"
            return
        }

        $script:Controls.UpdateText.Text = "Mise à jour disponible : $latest"
        $script:Controls.CheckUpdateButton.Content = "● INSTALLER $latest"
        if ($Interactive) {
            $notes = ''
            if ($manifest.PSObject.Properties.Name -contains 'notes' -and $manifest.notes) { $notes = "`n`n$($manifest.notes)" }
            $updateMessage = "La version $latest est disponible.$notes`n`nInstaller maintenant ?"
            if (Confirm-LauncherAction -Message $updateMessage -Title "Mise à jour ZED'S DEAD") {
                Install-LauncherUpdate -Manifest $manifest
            }
        }
    }
    catch {
        $statusCode = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 404) {
            $script:Controls.UpdateText.Text = 'Vous avez la dernière mise à jour.'
            if ($Interactive) { Show-LauncherMessage 'Vous avez la dernière mise à jour.' 'Mise à jour' 'Information' }
        }
        else {
            $script:Controls.UpdateText.Text = 'Serveur de mise à jour indisponible'
            if ($Interactive) { Show-LauncherMessage $_.Exception.Message 'Mise à jour' 'Warning' }
        }
    }
}

$script:Window.Title = $script:Config.launcher.name
$backgroundPath = Join-Path $script:LauncherRoot 'zeds-dead-background.png'
if (Test-Path -LiteralPath $backgroundPath -PathType Leaf) {
    $backgroundImage = [Windows.Media.Imaging.BitmapImage]::new([Uri]$backgroundPath)
    $backgroundBrush = [Windows.Media.ImageBrush]::new($backgroundImage)
    $backgroundBrush.Stretch = [Windows.Media.Stretch]::UniformToFill
    $script:Window.Background = $backgroundBrush
}
$logoPath = Join-Path $script:LauncherRoot 'zeds-dead-logo.png'
if (Test-Path -LiteralPath $logoPath -PathType Leaf) {
    $logoImage = [System.Windows.Media.Imaging.BitmapImage]::new()
    $logoImage.BeginInit()
    $logoImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $logoImage.UriSource = [Uri]$logoPath
    $logoImage.EndInit()
    $logoImage.Freeze()
    $script:Controls.HeaderLogoImage.Source = $logoImage
    $script:Controls.HeroLogoImage.Source = $logoImage
    $script:Window.Icon = $logoImage
}
$iconPath = Join-Path $script:LauncherRoot 'zeds-dead-logo.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $script:Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath)
}
$script:Window.ShowInTaskbar = $true
$displayVersion = if ($script:Config.launcher.displayVersion) { [string]$script:Config.launcher.displayVersion } else { [string]$script:Config.launcher.version }
$script:Controls.VersionText.Text = "v$displayVersion — $($script:Config.launcher.credit)"
$script:Controls.KeepModsCheck.IsChecked = [bool]$script:SaveMods
$script:Controls.AskBeforeLaunchCheck.IsChecked = [bool]$script:Config.launcher.askBeforeLaunch
$script:Controls.MusicPlayer.Volume = [Math]::Max(0.0, [Math]::Min(1.0, [double]$script:Config.launcher.musicVolume))
$script:IsMusicPlaying = $false
$script:Controls.FrenchButton.Add_Click({ $script:Language = 'fr'; Update-Language })
$script:Controls.EnglishButton.Add_Click({ $script:Language = 'en'; Update-Language })

$script:Controls.ServersNavButton.Add_Click({ $script:Controls.MainTabs.SelectedItem = $script:Controls.ServersTab })
$script:Controls.DiscordButton.Add_Click({
    try { Open-AllowedUri $script:Config.launcher.discordUrl @('https') } catch { Show-LauncherMessage $_.Exception.Message 'Discord' 'Warning' }
})
$script:Controls.VoteButton.Add_Click({
    try { Open-AllowedUri $script:Config.launcher.voteUrls[0] @('https') } catch { Show-LauncherMessage $_.Exception.Message 'Vote Top-Games' 'Warning' }
})
$script:Controls.VoteButton2.Add_Click({
    try { Open-AllowedUri $script:Config.launcher.voteUrls[1] @('https') } catch { Show-LauncherMessage $_.Exception.Message 'Vote Top-Serveurs' 'Warning' }
})
$script:Controls.MusicButton.Add_Click({
    try {
        $musicPath = Get-FullSafePath (Join-Path $script:LauncherRoot ([string]$script:Config.launcher.musicFile))
        if (-not (Test-Path -LiteralPath $musicPath -PathType Leaf)) {
            throw "Fichier audio introuvable : $([IO.Path]::GetFileName($musicPath))"
        }
        if ($script:IsMusicPlaying) {
            $script:Controls.MusicPlayer.Pause()
            $script:Controls.MusicButton.Content = '♫'
            $script:IsMusicPlaying = $false
        }
        else {
            if ($null -eq $script:Controls.MusicPlayer.Source) { $script:Controls.MusicPlayer.Source = [Uri]$musicPath }
            $script:Controls.MusicPlayer.Play()
            $script:Controls.MusicButton.Content = '❚❚'
            $script:IsMusicPlaying = $true
        }
    } catch { Show-LauncherMessage $_.Exception.Message 'Musique' 'Warning' }
})
$script:Controls.MusicPlayer.Add_MediaEnded({
    $script:Controls.MusicPlayer.Position = [TimeSpan]::Zero
    $script:Controls.MusicPlayer.Play()
})

$script:Controls.MinimizeButton.Add_Click({ $script:Window.WindowState = [System.Windows.WindowState]::Minimized })
$script:Controls.CloseButton.Add_Click({ $script:Window.Close() })
$script:Controls.TitleBar.Add_MouseLeftButtonDown({
    if ($_.ChangedButton -eq [System.Windows.Input.MouseButton]::Left -and $_.Source -eq $script:Controls.TitleBar) { $script:Window.DragMove() }
})
$script:Controls.ScumPathButton.Add_Click({
    try {
        if (Select-ScumFolder -Required $false) {
            $script:ActiveModsRoot = Get-FullSafePath (([string]$script:Config.mods.activeDirectory).Replace('{scumPath}', $script:GamePath))
            $script:InactiveModsRoot = Get-FullSafePath (([string]$script:Config.mods.inactiveDirectory).Replace('{scumPath}', $script:GamePath))
            Refresh-ModRows
            Set-Status "Dossier SCUM : $script:GamePath"
        }
    } catch { Show-LauncherMessage $_.Exception.Message 'Dossier SCUM' 'Error' }
})
$script:Controls.OpenModsButton.Add_Click({
    try {
        New-Item -ItemType Directory -Path $script:ModCacheRoot -Force | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList @($script:ModCacheRoot) | Out-Null
    } catch { Show-LauncherMessage $_.Exception.Message 'Mods' 'Error' }
})
$script:Controls.CopyAddressButton.Add_Click({
    $server = Get-SelectedServer
    if ($null -ne $server) { [Windows.Clipboard]::SetText("$($server.host):$($server.port)"); Set-Status 'Adresse IP copiée.' }
})
$script:Controls.ConnectButton.Add_Click({
    try {
        $server = Get-SelectedServer
        if ($null -eq $server) { throw 'Sélectionnez un serveur.' }
        if ($server.host -notmatch '^[a-zA-Z0-9.-]+$' -or [int]$server.port -lt 1 -or [int]$server.port -gt 65535) { throw 'Adresse serveur invalide.' }
        if ([bool]$script:Controls.AskBeforeLaunchCheck.IsChecked -and -not (Confirm-LauncherAction "Rejoindre $($server.name) ?")) { return }
        $script:Controls.MusicPlayer.Stop()
        $script:IsMusicPlaying = $false
        $script:Controls.MusicButton.Content = '♫'
        Set-Status 'Activation des mods…'
        Activate-ManagedMods
        Set-Status 'Lancement de SCUM…'
        Start-ScumGame $server
    } catch { Show-LauncherMessage $_.Exception.Message 'Connexion' 'Error' }
})
$script:Controls.RefreshServersButton.Add_Click({
    Set-Status 'Vérification des serveurs…'
    foreach ($server in $script:Config.servers) {
        if (-not (Test-HttpsUri $server.statusUrl)) {
            $script:ServerStatus[$server.id] = @{ Status=$script:Translations[$script:Language].NotConfigured; Players='—' }
            continue
        }
        try {
            $response = Invoke-RestMethod -Uri $server.statusUrl -Method Get -TimeoutSec 5
            $attributes = if ($response.data -and $response.data.attributes) { $response.data.attributes } else { $response }
            $online = if ([string]$attributes.status -eq 'online' -or [bool]$attributes.online) { 'En ligne' } else { 'Hors ligne' }
            $playerCount = if ($null -ne $attributes.players) { $attributes.players } else { $response.players }
            $maxPlayerCount = if ($null -ne $attributes.maxPlayers) { $attributes.maxPlayers } else { $response.maxPlayers }
            $players = if ($null -ne $playerCount -and $null -ne $maxPlayerCount) { "$playerCount/$maxPlayerCount" } elseif ($null -ne $playerCount) { "$playerCount" } else { '—' }
            $script:ServerStatus[$server.id] = @{ Status=$online; Players=$players }
        } catch {
            $script:ServerStatus[$server.id] = @{ Status='Indisponible'; Players='—' }
        }
    }
    Refresh-ServerRows
    Set-Status $script:Translations[$script:Language].Ready
})
$script:Controls.InstallModButton.Add_Click({
    try {
        $package = Get-SelectedPackage
        if ($null -eq $package) { throw 'Sélectionnez un mod.' }
        if (Install-ManagedPackage -Package $package -ConfirmReplace $true) {
            Refresh-ModRows
            Set-Status "$($package.name) téléchargé dans le dossier MOD."
        }
    } catch { Show-LauncherMessage $_.Exception.Message 'Installation du mod' 'Error'; Set-Status 'Installation annulée.' }
})
$script:Controls.RemoveModButton.Add_Click({
    try {
        if (Confirm-LauncherAction "Supprimer tous les mods ZED'S DEAD téléchargés et activés ?") {
            Remove-AllManagedMods
            Set-Status "Mods ZED'S DEAD supprimés."
        }
    }
    catch { Show-LauncherMessage $_.Exception.Message 'Suppression du mod' 'Error' }
})
$script:Controls.CheckUpdateButton.Add_Click({
    Check-LauncherUpdate -Interactive $true
})
$script:Controls.KeepModsCheck.Add_Checked({ $script:SaveMods = $true; Save-UserSettings })
$script:Controls.KeepModsCheck.Add_Unchecked({ $script:SaveMods = $false; Save-UserSettings })
$script:Window.Add_ContentRendered({
    try {
        if ([bool]$script:Config.mods.autoInstallOnFirstRun) {
            Set-Status "Vérification des mods ZED'S DEAD…"
            Sync-ModManifest
            if ($script:SaveMods -and -not (Get-Process -Name 'SCUM','SCUM-Win64-Shipping' -ErrorAction SilentlyContinue)) {
                Activate-ManagedMods
            }
            else {
                Ensure-ModCache
            }
            Set-Status 'Mods à jour. Prêt à rejoindre.'
        }
    }
    catch { Show-LauncherMessage $_.Exception.Message 'Téléchargement des mods' 'Error'; Set-Status 'Téléchargement des mods incomplet.' }
    try {
        $musicPath = Get-FullSafePath (Join-Path $script:LauncherRoot ([string]$script:Config.launcher.musicFile))
        if (Test-Path -LiteralPath $musicPath -PathType Leaf) {
            $script:Controls.MusicPlayer.Source = [Uri]$musicPath
            $script:Controls.MusicPlayer.Play()
            $script:Controls.MusicButton.Content = '❚❚'
            $script:IsMusicPlaying = $true
        }
    }
    catch { }
    Check-LauncherUpdate -Interactive $false
})
$script:Window.Add_Closing({
    $script:Controls.MusicPlayer.Stop()
    if (-not [bool]$script:Controls.KeepModsCheck.IsChecked) {
        try { Deactivate-ManagedMods }
        catch { Show-LauncherMessage $_.Exception.Message 'Désactivation des mods' 'Warning' }
    }
})

Update-Language
try {
    $script:Window.ShowDialog() | Out-Null
    Write-LauncherLog 'Fermeture normale du launcher.'
}
catch {
    Write-LauncherLog 'Erreur affichage fenetre.' $_.Exception
    Show-LauncherMessage $_.Exception.Message 'Erreur du launcher' 'Error'
}

