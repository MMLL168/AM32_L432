# 開發日誌

---

## 2026-03-12

### 修改原因
建立專案開發準則，確保所有修改都有詳細記錄，便於日後追蹤與維護。

### 解決方式
- 建立 `CLAUDE.md`，定義協作準則：所有回應使用繁體中文，每次修改須在本日誌記錄日期、修改原因與解決方式。
- 初始化本 `devlog.md` 作為開發日誌起始點。

---

## 2026-03-12（二）

### 修改原因
需要為 NUCLEO-L432KC 開發板新增專屬 target 定義，以便編譯出對應的韌體。
使用者的腳位規劃（PA0/PA4/PA5 BEMF、PA1 中性點、PA10/PA9/PA8 高側、PB1/PB0/PA7 低側、PA2 Dshot）完全符合現有 `HARDWARE_GROUP_L4_A + COMP_ORDER_L4_A_045` 配置。

### 解決方式
在 `Inc/targets.h` 第 308 行，`REF_L431_CAN` 之後新增 `NUCLEO_L432KC` target：
- `HARDWARE_GROUP_L4_A`：使用 TIM1 互補 PWM 驅動三相、TIM15 CH1（PA2）接收 Dshot
- `COMP_ORDER_L4_A_045`：BEMF 順序 PA0→A相、PA4→B相、PA5→C相
- `DEAD_TIME 80`：與 REF_L431 相同預設值
- `TARGET_VOLTAGE_DIVIDER 260`：預設分壓比（可依實際電路調整）
- `USE_SERIAL_TELEMETRY`、`RAMP_SPEED_LOW/HIGH_RPM 1`：基本功能啟用
- target 名稱由 `NUCLEO_L432KC` 改為 `NUCLEO_L432KC_L431`，原因：Makefile 的 `get_targets` 函數以 `_L431` 篩選 L431 系列 target，名稱不含 `_L431` 則 make 找不到此 target
- 新增 `.vscode/tasks.json`，設定預設建置任務為 `make NUCLEO_L432KC_L431`，可在 VS Code 以 `Ctrl+Shift+B` 觸發編譯

---

## 2026-03-12（三）

### 修改原因
使用者需要在 VS Code 進行單步 debug。原始 ldscript.ld 將 FLASH 起始位址設為 `0x08001000`（保留前 4KB 給 bootloader），但開發板上沒有 bootloader，MCU 無法正常啟動，導致無法除錯。

### 解決方式
- 新增 `Mcu/l431/ldscript_debug.ld`：將 FLASH 起始位址改為 `0x08000000`，大小從 57K 擴大為 61K（加回 bootloader 的 4KB），EEPROM 與 FILE_NAME 位址維持不變。僅供開發除錯使用，正式韌體仍使用原始 ldscript.ld。
- 更新 `.vscode/tasks.json`：
  - 新增 "Build NUCLEO_L432KC (Debug)" 任務（預設 `Ctrl+Shift+B`），使用 `LDSCRIPT_L431=Mcu/l431/ldscript_debug.ld` 覆蓋 linker script
  - 保留 "Build NUCLEO_L432KC (Release)" 任務供正式燒錄使用
- 更新 `.vscode/launch.json`：
  - 新增 "NUCLEO_L432KC Debug (STLink)" 設定，preLaunchTask 指向 debug build 任務，F5 可自動編譯後啟動除錯
  - 使用 NUCLEO-L432KC 板載 ST-Link + OpenOCD + stm32l4x target

---

## 2026-03-13

### 修改原因
馬達轉動不順、desync 持續發生。分析發現 `eepromBuffer.motor_poles` 在 EEPROM 未初始化時為 `0xFF=255`，導致 `32/255=0`（整數除法），使 `low_rpm_level` 和 `high_rpm_level` 均為 0，低轉速保護機制完全失效，造成啟動時油門控制異常、失步頻發。

測試馬達為 MT2204-2300KV（14 極），訊號源改為 Pixhawk 6C Dshot，問題依然存在，確認根因為 motor_poles 未初始化。

### 解決方式
在 `Src/main.c` 第 770 行 `low_rpm_level` 計算之前加入安全檢查：
- 若 `motor_poles == 0` 或 `> 28`（無效值），自動設為 14（MT2204 等常見小型馬達的極數）
- 避免整數除以零導致保護計算失效
- 此修改對所有 target 均有效（通用安全修正）

---

## 2026-03-13（二）

### 修改原因
馬達油門 25% 以上明顯卡卡，無法順暢加速。

**根本原因分析：**
EEPROM 未初始化時 `eepromBuffer.motor_kv = 0xFF = 255`，導致：
- `motor_kv = (255 × 40) + 20 = 10,220`（錯誤值，遠高於實際 2300KV）
- `low_rpm_level  = 10220 / 100 / 2 = 51`（千 ERPM）
- `high_rpm_level = 10220 / 12  / 2 = 425`（千 ERPM）

主迴圈中：
```c
duty_cycle_maximum = map(k_erpm, 51, 425, 400, 2000)
```
MT2204-2300KV 正常運轉 k_erpm ≈ 20~60，遠低於 `low_rpm_level = 51`，所以 `duty_cycle_maximum` 永遠被鎖在 400（最大油門的 20%）。一旦輸入油門超過 400（約 25%），馬達取不到更多功率，造成卡頓失步。

### 解決方式
在 `Src/main.c` 第 641 行 `motor_kv` 計算之後加入安全檢查：
- 若 `eepromBuffer.motor_kv == 0xFF`（EEPROM 未初始化），強制設 `motor_kv = 2000`
- 對應正確的 `low_rpm_level = 11`、`high_rpm_level = 95`，油門限制恢復正常
- 長期解決方案：使用 AM32 Configurator 設定正確的 motor_kv（MT2204-2300KV 應設 57）

---

## 2026-03-13（三）

### 修改原因
馬達仍持續卡頓，電供電流僅 0.10~0.16A（10V × 0.13A = 1.3W），`desync_happened` 飛速增加（約 6次/秒），馬達不斷在停止重啟循環。

**根本原因分析：**
`eepromBuffer.startup_power = 0xFF = 255`（EEPROM 未初始化），超出 49-151 有效範圍，導致：
```c
min_startup_duty = minimum_duty_cycle; // = 0（起動 duty cycle = 0）
```
馬達啟動時幾乎無驅動電壓 → BEMF 信號過弱 → 單向模式下 desync 觸發 `running=0` → 重啟 → 無限循環。
電供低電流（1.3W）正是此現象：馬達每秒停止重啟 6 次，平均功率極低。

同時修正 `mech_rpm` 公式錯誤：`e_rpm` 是 ERPM/100，乘以 10 計算機械轉速差了 10 倍，應乘以 100。

### 解決方式
1. `Src/main.c` `startup_power` 安全檢查：若 `== 0xFF` 則 `min_startup_duty = minimum_duty_cycle + 80`（合理啟動功率預設）
2. `mech_rpm` 公式修正：`(e_rpm * 10)` → `(e_rpm * 100)`，Live Watch 顯示正確機械轉速（約 2500 RPM）

---

## 2026-03-13（四）

### 修改原因
馬達只有 14% 油門看起來正常，超過後即刻卡頓，且 Live Watch 顯示 `input = 604` ≈ `newinput × 2`（不合理的兩倍關係）。

**根本原因分析：**
`eepromBuffer.bi_direction = 0xFF = 255`（EEPROM 未初始化），255 為 truthy，觸發雙向馬達輸入處理路徑：
```c
if (eepromBuffer.bi_direction) {
    adjusted_input = ((newinput - 48) * 2 + 47);  // 雙向公式，放大 2 倍
}
```
- 48~1047 範圍（0~50% 油門）：adjusted_input = newinput×2，可用但油門範圍只有一半
- newinput≥1048（>50% 油門）：換用另一條公式，adjusted_input 驟降至 47（最低值）
- 這就是「14% 可以，以上全部卡死」的根本原因

### 解決方式
`loadEEpromSettings()` 加入 `bi_direction` 安全檢查：若 `== 0xFF` → 強制設為 0（單向模式）。修正後 `adjusted_input = newinput`，Pixhawk 0~100% 油門完整映射。

---

## 2026-03-13（五）

### 修改原因
`bi_direction` 的 0xFF 修正在 `loadEEpromSettings()`（第 648 行）加入後，問題依然存在。

**根本原因（第二層）：**
`eepromBuffer.rc_car_reverse == 0xFF`（EEPROM 未初始化），在 `main()` 第 1746 行：
```c
if (eepromBuffer.rc_car_reverse) {  // 0xFF = truthy！
    eepromBuffer.bi_direction = 1;   // 強制覆蓋 loadEEpromSettings 的修正
    ...
}
```
`loadEEpromSettings()` 在第 1727 行設 `bi_direction = 0`，但緊接著第 1746 行的 `rc_car_reverse` 檢查（truthy）又把它強制回 1，修正完全被蓋掉。

### 解決方式
在 `loadEEpromSettings()` 的 `bi_direction` 修正旁邊加入 `rc_car_reverse` 安全檢查：
- 若 `eepromBuffer.rc_car_reverse == 0xFF` → 強制設為 0（關閉 RC car 倒車模式）
- 確保 `main()` 第 1746 行的 `if (eepromBuffer.rc_car_reverse)` 不會被 0xFF 觸發，`bi_direction` 修正得以保留

---

## 2026-03-13（六）

### 修改原因
修正 `rc_car_reverse = 0` 後，馬達完全無法啟動（oil throttle 無反應，`running` 永遠為 0）。

**根本原因（連鎖效應）：**
舊韌體（rc_car_reverse = 0xFF）觸發以下區塊：
```c
if (eepromBuffer.rc_car_reverse) {
    eepromBuffer.use_sine_start = 0;  // 副作用：清除 use_sine_start
    eepromBuffer.bi_direction = 1;    // 問題所在
}
```
這個副作用讓 `use_sine_start = 0`，使馬達能啟動。修正 `rc_car_reverse = 0` 後，`use_sine_start` 保留 `0xFF`，導致啟動門檻：
```
input >= 47 + (80 × 255) = 20447
```
input 最大值只有 2047，門檻永遠達不到，馬達永遠無法啟動。

### 解決方式
在 `loadEEpromSettings()` 加入 `use_sine_start` 安全檢查：
- 若 `eepromBuffer.use_sine_start == 0xFF` → 強制設為 0（關閉正弦啟動模式）
- 恢復馬達啟動門檻為正常值 `input >= 47`

---

## 2026-03-13（七）

### 修改原因
馬達在油門 38% 以下最高轉速（mech_rpm ≈ 9857），38% 以上 duty_cycle_maximum 從 1700 驟降至 800，轉速反而越來越低。

**根本原因（兩個 0xFF 保護機制誤觸發）：**

1. `eepromBuffer.stall_protection = 0xFF`（truthy）→ Stall PID 持續運作
   程式碼註解明確說明：**"for crawlers and rc cars only, do not use for multirotors"**
   0xFF 啟用後，當轉速下降時 PID 不斷加 duty，多旋翼反而更快 desync，形成正反饋惡化。

2. `eepromBuffer.stuck_rotor_protection = 0xFF`（truthy）→ 卡死轉子保護過敏
   `bemf_timeout_happened > 10` 就執行 `allOff()`，高油門時 BEMF 時序偏移即誤判切電。

### 解決方式
在 `loadEEpromSettings()` 加入安全檢查：
- `stall_protection == 0xFF` → 設為 0（多旋翼不適用爬行保護）
- `stuck_rotor_protection == 0xFF` → 設為 0（待 EEPROM 正確初始化後再視需要啟用）

---

## 2026-03-13（八）

### 修改原因
stall/stuck_rotor 修正後，38% 切電現象完全相同，代表那兩個不是主因。

**根本原因：`comp_pwm = 0xFF`（互補 PWM 啟用）**

- `comp_pwm = 0`（舊韌體 rc_car_reverse 強制）：低側 GPIO OFF，浮動相 BEMF 信號乾淨
- `comp_pwm = 0xFF`（我們修正後）：低側 TIM1 CHxN 主動換相，雜訊耦合浮動相，高 duty 時 BEMF 零交叉偵測失敗

失敗鏈：`comp_pwm雜訊 → BEMF失敗 → INTERVAL_TIMER > 45000 → old_routine=1 → 時序突變 → desync → running=0 → allOff重啟循環`

### 解決方式
`loadEEpromSettings()` 加入：`comp_pwm == 0xFF` → 設為 **1**（啟用互補 PWM）

**修正更新：**
HARDWARE_GROUP_L4_A 的設計目標就是互補輸出（TIM1 主輸出 + CHxN 互補輸出驅動 6 個 MOSFET），comp_pwm = 0 反而讓低側只靠體二極體飛輪，高頻 PWM 下產生更多熱與雜訊，反而是「轉轉停停 卡卡聲音」的原因。正確預設為 1。

---

## 2026-03-13（九）

### 修改原因
修正 `comp_pwm` 後繼續分析仍未解決的 desync 問題。

**根本原因：`auto_advance = 0xFF` + `brake_on_stop = 0xFF`**

1. `eepromBuffer.auto_advance = 0xFF`（truthy）→ 動態超前角啟用
   ```c
   auto_advance_level = map(duty_cycle, 100, 2000, 13, 23); // 高 duty 時超前角最大 23°
   ```
   超前角增大縮短 BEMF 偵測視窗（換相早於零交叉）→ INTERVAL_TIMER 超時 → `old_routine=1` → 換相時序突變 → desync

2. `eepromBuffer.brake_on_stop = 0xFF`（truthy）→ 停止時主動制動
   停止期間短路三相，干擾低速 BEMF 偵測，重啟時誤判零交叉

**完整 desync 鏈（修正後理解）：**
```
auto_advance=0xFF → 高 duty 超前角 23°
  → BEMF 偵測視窗縮短
  → 零交叉偵測失敗 → INTERVAL_TIMER > 45000
  → bemf_timeout_happened++ → old_routine=1（polling 模式）
  → 換相時序突變 → desync_check 觸發
  → bi_direction=0 且 input>47 → running=0（馬達停止）
  → allOff() + startMotor() → 重啟循環
```

### 解決方式
在 `loadEEpromSettings()` 加入安全檢查（`Src/main.c` 第 666-671 行）：
- `comp_pwm == 0xFF` → 設為 1（啟用互補 PWM，正確驅動 HARDWARE_GROUP_L4_A）
- `auto_advance == 0xFF` → 設為 0（關閉動態超前角，BEMF 偵測視窗穩定）
- `brake_on_stop == 0xFF` → 設為 0（關閉停止制動，低速 BEMF 偵測正常）

---
