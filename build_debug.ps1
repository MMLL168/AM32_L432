# Debug build script - 忽略 python3 簽章錯誤，直接複製 ELF 供 VS Code 除錯使用
# ⚠️  警告：此腳本產生的 hex 從 0x08000000 開始，僅供 ST-Link 直接燒錄，
#         不可透過 AM32 Configurator / bootloader 刷入！
#         正式刷機請執行 build_release.ps1
Write-Host "[DEBUG BUILD] 此 hex 不可透過 AM32 bootloader 刷入，僅供 ST-Link 使用" -ForegroundColor Yellow
make NUCLEO_L432KC_L431 LDSCRIPT_L431=Mcu/l431/ldscript_debug.ld
$elf = "obj/AM32_NUCLEO_L432KC_L431_2.20.elf"
if (Test-Path $elf) {
    Copy-Item -Force $elf obj/debug.elf
    Copy-Item -Force Mcu/l431/STM32L4x1.svd obj/debug.svd
    Copy-Item -Force Mcu/l431/openocd.cfg obj/openocd.cfg
    Write-Host "Debug files ready: obj/debug.elf" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Build failed: ELF not found" -ForegroundColor Red
    exit 1
}
