# Release build script - 產生可透過 AM32 Configurator / bootloader 刷入的正式 hex
# FLASH 從 0x08001000 開始，需搭配 AM32 bootloader
Write-Host "[RELEASE BUILD] 正式韌體，可透過 AM32 bootloader 刷入" -ForegroundColor Cyan
make NUCLEO_L432KC_L431
$hex = "obj/AM32_NUCLEO_L432KC_L431_2.20.hex"
if (Test-Path $hex) {
    Write-Host "Release hex ready: $hex" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Build failed: hex not found" -ForegroundColor Red
    exit 1
}
