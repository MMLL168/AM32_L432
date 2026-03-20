# 開發日誌

---

## 2026-03-20

### 修改原因
移除虛擬中性點 10nF 電容後，mech_rpm 可到 16,000 RPM，但超過 16,000 就失步（零交叉重置）。
調整 INTERVAL_TIMER gate 從 50%→40% 無效，問題根本原因確認：

**高油門時 CCR5 被提前 clamp，切換噪音進入 BEMF 偵測視窗**：
- COMP_MIN_BEMF_WINDOW=500：clamped CCR5 = 1665-500 = 1165
- 78% 油門 adjusted_duty=1302 > CCR5=1165 → CNT 1165~1302 段 PWM 仍在 ON，但 blanking 已結束 → 切換噪音直接進入偵測窗口 → 假 ZC 通過 filter_level=20 確認 → 失步

### 解決方式

**`Inc/targets.h`**：重新啟用 `USE_COMP1_BLANKING`，將 `COMP_MIN_BEMF_WINDOW` 從 500 改為 100：
```c
#define USE_COMP1_BLANKING
#define COMP_BLANKING_MARGIN    200
#define COMP_MIN_BEMF_WINDOW    100   // 原 500 → 100
```

效果：
- 78% 油門：CCR5 = 1302+200 = 1502（完整覆蓋 duty+振鈴），BEMF 窗口 = 163 ticks = 2μs/cycle
- 90% 油門：CCR5 clamp 到 1665-100=1565，仍高於 duty=1499，提供 66 ticks 振鈴沉澱 + 100 ticks BEMF 窗口

其他本次有效修改（本日確認）：
- 虛擬中性點 10nF 電容移除：BEMF 訊號品質大幅提升，RPM 從 1000 → 16,000
- COMP1 hysteresis = MEDIUM (25mV)：過濾 PWM 雜訊
- filter_level = 20（固定）：提高噪音拒絕能力
- PWM 頻率 48kHz（原 24kHz）：電流漣波減半，BEMF 更乾淨
- INTERVAL_TIMER gate = 40%（原 50%）：高速時 ZC 更早被接受

---

## 2026-03-19（五）

### 修改原因
回顧 devlog 後確認：12000 RPM 是在**完全沒有任何 blanking** 的狀態下達到的（2026-03-17 記錄）。當時失速的根因是假 ZC → commutation_interval 縮短 → k_erpm 上升 → `duty_cycle_maximum` 被 `map(k_erpm, low_rpm_level, high_rpm_level, ...)` 壓低（doom loop，前提是 `low_rpm_throttle_limit=1`）。

但 `low_rpm_throttle_limit=0` 早在 2026-03-19 修正時就已套用（`#ifdef NUCLEO_L432KC_L431` 強制設為 0）。doom loop 條件不再成立。

**根本原因：軟體 blanking（`CNT < CCR5`）是多餘的，且反而遮蔽有效 BEMF 訊號**

- 測試 `COMP_ORDER_L4_A_540`（A↔C 對調）→ 馬達更糟，確認原始 045 接線正確
- 軟體 blanking 使 COMP 中斷在 CNT < CCR5 期間全部被丟棄；高 duty 時 CCR5=2832（佔 85% 週期），大量真實 ZC 訊號被遮蔽 → 卡在 1000 RPM

### 解決方式

**`Inc/targets.h`**：移除 `USE_COMP1_BLANKING`（改為 comment out）：
```c
// 改前：
#define USE_COMP1_BLANKING
// 改後：
//#define USE_COMP1_BLANKING   // 已停用（doom loop 根因已由 low_rpm_throttle_limit=0 修正）
```

**`COMP_ORDER_L4_A_540` 測試結果**：更糟，已改回 045（原接線正確）。

**測試結果**：移除 blanking 後 mech_rpm 提升至 8500-9700 RPM（35% 油門），bemf_timeout=0，old_routine=0，zero_crosses 穩定累積。但每約 0.5 秒出現一次 desync（zero_crosses 歸零後重新累積）→ 推斷 PWM 切換噪音偶爾穿透 COMP1 造成假 ZC。

**追加修正：COMP1 輸入磁滯（hysteresis）**

在 `Mcu/l431/Src/peripherals.c` MX_COMP1_Init：
```c
// 改前：
COMP_InitStruct.InputHysteresis = LL_COMP_HYSTERESIS_NONE;
// 改後：
COMP_InitStruct.InputHysteresis = LL_COMP_HYSTERESIS_MEDIUM;  // 25mV，過濾 PWM 噪音
```

STM32L4 COMP1 磁滯選項：NONE(0mV) / LOW(10mV) / MEDIUM(25mV) / HIGH(50mV)。
選 MEDIUM：12V 系統 BEMF 真實 ZC 幅度為數百 mV（分壓後），25mV 磁滯可過濾 PWM 切換雜訊，但不影響正常 ZC 偵測。

**追加：診斷快照 `dbg_snap`**

在 `Src/main.c` 新增 `volatile DbgSnap_t dbg_snap`，於每次 waitTime 計算後同步寫入所有關鍵欄位（comm_interval, advance, waitTime, filter_level, zero_crosses, duty_cycle, adjusted_duty, input, old_routine, bemf_timeout），確保 Live Watch 截圖時所有數值屬於同一 commutation cycle，避免異步讀值造成誤判。

---

## 2026-03-19（六）

### 硬體關鍵發現：虛擬中性點 10nF 電容造成 BEMF 相位偏移

**現象**：移除虛擬中性點對 GND 的 10nF 濾波電容後，mech_rpm 從原本卡在 ~1000-1300 RPM 大幅提升至 **14,214 RPM**（69% 油門），zero_crosses 穩定維持 10000，bemf_timeout=0，old_routine=0。

**根本原因**：10nF 電容與虛擬中性點分壓電阻形成 RC 低通濾波器，在換相頻率（~10kHz）附近引入相位延遲，導致 COMP1 偵測到的零交叉點時序偏離真實 BEMF ZC 時間點。此時序誤差造成換相過早/過晚 → 假 ZC 或漏 ZC → desync 循環。

**結論**：虛擬中性點（PA1）**不應加對 GND 的濾波電容**。若需要雜訊過濾，應選用更小容值（< 1nF）或改用串聯電阻方式，避免在 BEMF 頻率範圍內引入過大相位誤差。

**當前狀態（filter_level=16, COMP MEDIUM hysteresis, 48kHz PWM）**：
- mech_rpm：14,214 @ 69% 油門
- commutation_interval：203 ticks（101.5μs）
- advance：12 ticks，waitTime：87 ticks
- 偶爾 desync，尚在調查中

---

## 2026-03-19（四）

### 修改原因
12 張 Live Watch 截圖顯示軟體 blanking 修正有效（bemf_timeout 從 10-58 降至幾乎 0，old_routine=0 在 35-57% 油門成功運作，zero_crosses 累積至 527）。但馬達 RPM 仍卡在 ~1000-1250 RPM，無法加速。

**根本原因：高 duty 時 CCR5=0 造成完全無過濾**

原本 COMP_MIN_BEMF_WINDOW 邏輯：當 blanking_ccr + 500 >= tim1_arr 時設 CCR5=0（「停用 blanking」）。但 CCR5=0 等於軟體 blanking 門檻為 0，`CNT < 0` 恆 FALSE → 所有 COMP 邊緣都通過 → 高 duty（≥79%）時 PWM 切換噪音完全無過濾 → 偶爾假換相 → desync → zero_crosses 重置 → 循環卡在 startup。

截圖 9（79% 油門）：adj_duty=2634，CCR5=**0** → 噪音無過濾。截圖 11（100% 油門）：adj_duty=3333，CCR5=**0** → 同樣問題。

### 解決方式

**`Src/main.c`** CCR5 高 duty 路徑改為 clamp（不設為 0）：
```c
// 改前：TIM1->CCR5 = 0;
// 改後：
TIM1->CCR5 = (uint16_t)((uint32_t)tim1_arr - COMP_MIN_BEMF_WINDOW); // = 2832
```

效果：CCR5 最大 = 3332-500 = **2832**，確保：
- 軟體 blanking 始終覆蓋 0 到 CCR5 範圍（噪音被過濾）
- BEMF 偵測視窗始終至少 500 ticks（6.25μs）
- CCR5 永遠不為 0

---

## 2026-03-19（三）

### 修改原因
10 張 Live Watch 截圖顯示 `filter_level` 所有截圖均卡在 **12（最大值）**，`bemf_timeout_happened` 持續 10-58，馬達無法穩定加速。

**根本原因：TIM1 OC5 硬體 blanking 的「遮蔽結束假邊緣」**

每個 PWM 週期（41.7μs）：
1. CNT=0：OC5→HIGH，COMP1 輸出強制為 0
2. CNT=CCR5：OC5→LOW，COMP1 恢復真實值
3. 若真實 COMP=HIGH → EXTI 看到 0→1 rising edge（假邊緣）
4. COMP_IRQHandler 觸發，此時 CNT ≥ CCR5 → CNT < CCR5 檢查失效
5. INTERVAL_TIMER < average/2（才剛換相）→ else branch
6. getCompOutputLevel()==rising(0) → 1==0 FALSE → flag 沒清除
7. NVIC 立即重觸發 → 繞圈約 4000 次 → INTERVAL_TIMER 過半 → interruptRoutine() 假換相 → desync
8. filter_level 因此卡在 12，真實 ZC 被一起濾掉

此問題每 41.7μs 發生一次（rising=0 步驟，佔 50%）。

### 解決方式

**`Mcu/l431/Src/peripherals.c`**：
- 移除 COMP1 硬體 blanking：`OutputBlankingSource = LL_COMP_BLANKINGSRC_NONE`
- COMP_IRQHandler 的軟體檢查 `if (TIM1->CNT < TIM1->CCR5)` 仍保留有效
- TIM1->CCR5 仍由 main.c 動態更新（軟體門檻）
- 不再有 OC5→COMP1 閘控假邊緣，CPU overhead ~3-4%

---

## 2026-03-19（二）

### 修改原因
燒錄 `low_rpm_throttle_limit=0` 修正後，9 張 Live Watch 截圖顯示 `duty_cycle_maximum` 已升至 2000（修正有效），但 43%+ 油門時 `bemf_timeout_happened` 持續累積至 11-48，`zero_crosses` 僅 2-19，馬達持續 desync 無法加速。

**根本原因：高 duty 時 blanking 遮蔽整個 BEMF 偵測視窗**

CCR5 計算：`blanking_ccr = adjusted_duty_cycle + 200`。
- 低油門（17%，duty=355）：adj_duty=592，CCR5=792 → blanking 佔 24% → 76% BEMF 視窗 → 正常（bemf_timeout≈0）
- 高油門（100%，duty=2000）：adj_duty=3332，blanking_ccr=3532 → clamped 至 3331（= tim1_arr-1）→ 99.97% blanked → COMP1 幾乎永遠關閉 → 零交叉完全無法偵測 → 立即 desync

**加速過程的觸發機制**：
1. startup cap（400）→ zero_crosses 到 100 → duty 跳到目標值（866 或 2000）
2. adj_duty 急升 → CCR5 跟著升高 → blanking 遮蔽幾乎全部 BEMF 視窗
3. 無 ZC → bemf_timeout 累積 → old_routine → zero_crosses 重置 → 循環

### 解決方式

**`Inc/targets.h`** NUCLEO_L432KC_L431 section 新增：
```c
#define COMP_MIN_BEMF_WINDOW    500   // 高 duty 時保留的最小 BEMF 偵測視窗（~6.25μs）
```

**`Src/main.c`** CCR5 更新邏輯改為：
```c
uint32_t blanking_ccr = (uint32_t)adjusted_duty_cycle + COMP_BLANKING_MARGIN;
if (blanking_ccr + COMP_MIN_BEMF_WINDOW >= (uint32_t)tim1_arr) {
    TIM1->CCR5 = 0;  // 高 duty 停用 blanking，保留 BEMF 偵測視窗
} else {
    TIM1->CCR5 = (uint16_t)blanking_ccr;
}
```

**門檻計算**：adj_duty >= 3332-200-500=2632（= duty_cycle 1579/2000 = 79%）時停用 blanking。
此時 BEMF 視窗夠大（500 ticks = 6.25μs），PWM 振鈴在高轉速下衰減更快，blanking 效益減低，直接停用影響較小。

---

## 2026-03-19

### 修改原因
燒錄 blanking 修正（中斷風暴已解決）後，9 張 Live Watch 截圖顯示馬達仍無法超過 1285 RPM，且不論油門 28%/53%/100%，`duty_cycle_maximum` 永遠停在 **400**。

**根本原因（EEPROM 修正的副作用）：**

1. `duty_cycle_maximum = map(k_erpm, low_rpm_level=11, high_rpm_level=95, 400, 2000)` — k_erpm=4~10 均 < low_rpm_level=11，`map()` 回傳最低值 400，永遠鎖死
2. k_erpm 無法突破 11（= 1571 RPM 機械），因為 400 duty（= 20% × 12V = 2.4V 等效）帶槳時最多約 1285 RPM — 永遠低於 1571 RPM 門檻 → doom loop（duty 鎖 → RPM 低 → k_erpm 低 → duty 繼續鎖）
3. **副作用來源**：EEPROM 舊值 `motor_kv == 0xFF` 時，救援程式碼設了 `low_rpm_throttle_limit = 0`（保護停用）。修正 EEPROM 存入 motor_kv=57 後，下次開機 0xFF 條件不觸發 → `low_rpm_throttle_limit` 回預設值 1（保護開啟）→ 油門被鎖
4. **附加確認**：`adjusted_duty_cycle = 667 = 400×3332/2000`，即 TIM1_AUTORELOAD=3332（80MHz/24kHz-1，預設 24kHz，非 40kHz）。CCR5=867=667+200 ✓ blanking 計算正確。`bemf_timeout_happened = 0` ✓ 中斷風暴已消除。

### 解決方式
在 `Src/main.c` `loadEEpromSettings()` 中 `low_rpm_level`/`high_rpm_level` 計算之後加入：
```c
#ifdef NUCLEO_L432KC_L431
    low_rpm_throttle_limit = 0; // 開發板無過流風險，停用低轉速油門上限
#endif
```
其他 target 不受影響。開發板帶槳測試無需此保護；正式量產 ESC 仍維持保護機制。

---

## 2026-03-17（二）

### 修改原因
燒錄 blanking 韌體後馬達反而更差：`mech_rpm` 最高 1785、多數 342~400，`bemf_timeout_happened` 持續累計到 11，`zero_crosses` 僅 22~90，`old_routine=1`（polling 模式），`filter_level=12`（卡頂）。

**根本原因：blanking 引發 EXTI 中斷風暴**

TIM1 OC5 blanking 啟動時，COMP1 輸出被強制拉到 0（LOW）。若當時 EXTI 設為 falling edge 觸發（`rising=1` 情況），此強制拉低會觸發假邊緣 → `COMP_IRQHandler` 被呼叫 → 計時器未達 `average_interval/2` 門檻 → 進入 else 分支 → `getCompOutputLevel() == rising (=1)` 為 FALSE（因 COMP 被 blanking 強制為 0）→ flag **不被清除** → 中斷 handler 返回後 NVIC 再次觸發 → 無限中斷風暴。

每個 40kHz PWM 週期（25μs）都會產生這個風暴，完全佔用 CPU，DShot DMA 回調無法執行，throttle 無法更新，馬達無法正常控制。

### 解決方式
在 **`Mcu/l431/Src/stm32l4xx_it.c`** `COMP_IRQHandler()` 中，EXTI flag 確認後加入 blanking 視窗檢查：

```c
#ifdef USE_COMP1_BLANKING
    if (TIM1->CNT < TIM1->CCR5) {
        LL_EXTI_ClearFlag_0_31(EXTI_LINE);
        return;  // blanking 視窗內的假邊緣，直接清除 flag 打破風暴
    }
#endif
```

原理：blanking 期間（`TIM1->CNT < TIM1->CCR5`），COMP1 輸出是硬體強制的，不是真實 BEMF。發現此情況時立即清除 EXTI flag 並返回，避免中斷風暴。blanking 結束後（CNT ≥ CCR5），COMP1 恢復真實比較，正常 ZC 偵測重新生效。

---

## 2026-03-17

### 修改原因
Live Watch 觀察確認：input=1272 時 duty_cycle 升至 1224，`commutation_interval` 出現異常短值（195 ticks，等效 ~7300 RPM，遠低於實際轉速），`advance` 數值與當下 `commutation_interval` 不對應 → 確認為 COMP1 無硬體 blanking，PWM 高 duty 切換振鈴穿透比較器，觸發假零交叉 → 換相時序紊亂 → mech_rpm 從 12000 掉回 8000 → duty_cycle_maximum 隨 k_erpm 下降被壓低 → doom loop。

### 解決方式
實作 **TIM1 OC5 → COMP1 hardware blanking**，三檔修改：

1. **`Inc/targets.h`**（`NUCLEO_L432KC_L431` 區段）：新增 `#define USE_COMP1_BLANKING` 和 `#define COMP_BLANKING_MARGIN 200`（~2.5μs at 80MHz）。用 `#ifdef` 保持其他 target 不受影響。

2. **`Mcu/l431/Src/peripherals.c`** `MX_TIM1_Init()`：
   - 在 CH4 初始化後加入 TIM1 CH5 配置（CCMR3=PWM mode 1+preload，CCER bit16 CC5E，CCR5=0）。CH5 無 GPIO 輸出，為純內部 blanking 信號。
   - COMP1 `OutputBlankingSource` 從 `LL_COMP_BLANKINGSRC_NONE` 改為 `LL_COMP_BLANKINGSRC_TIM1_OC5_COMP1`（含 `#ifdef` 條件編譯）。

3. **`Src/main.c`** `tenKhzRoutine()` SET_DUTY_CYCLE_ALL 之後：動態更新 `TIM1->CCR5 = adjusted_duty_cycle + COMP_BLANKING_MARGIN`（上限 tim1_arr-1）。邏輯：TIM1 UP 計數，CNT < CCR5 時 OC5 HIGH → COMP1 blanked，涵蓋 PWM 導通期 + 振鈴 margin。

---

## 2026-03-16（三）

### 修改原因
Debug 模式下 Live Watch 顯示多個 EEPROM 欄位含非 0xFF 的無效值（`use_sine_start=48`、`advance_level=162`、`motor_poles=146`），導致馬達完全無法啟動。根本原因：既有安全攔截只針對 `== 0xFF`，無法攔截 EEPROM 中其他非法值。其中 `use_sine_start=48` 造成啟動門檻 = `47 + 80×48 = 3887 > 2047`，是馬達不動的直接原因。

### 解決方式
修改 `Src/main.c` `loadEEpromSettings()` 函數，將所有 boolean/enum EEPROM 欄位從「只攔截 0xFF」改為「值域範圍檢查」：

1. **boolean 欄位（只允許 0 或 1）**：`dir_reversed`、`bi_direction`、`rc_car_reverse`、`use_sine_start`、`stall_protection`、`stuck_rotor_protection`、`comp_pwm`、`auto_advance`、`brake_on_stop`、`telemetry_on_interval` → 改為 `> 1` 條件，涵蓋 0xFF 及其他非法值（如 48、162）
2. **`variable_pwm`（0/1/2 三態）**：改為 `> 2` 條件
3. **`advance_level` 無效值**：在 `> 42 || (< 10 && > 3)` 分支中加入 `eepromBuffer.advance_level = 14`，避免無效值（如 162）殘留在 buffer 中，讓後續 `< 43 && > 9` 條件能正常計算 `temp_advance = 4`
4. **`eeprom_needs_save` 機制**：新增全域旗標 `uint8_t eeprom_needs_save`；`loadEEpromSettings()` 每次修正任何欄位時設為 1；`main()` 版本比對條件加入 `|| eeprom_needs_save`，觸發 `saveEEpromSettings()` 寫回 Flash。確保第一次開機修正後，EEPROM 實際儲存正確值，後續開機不再需要修正。

---

## 2026-03-16

### 修改原因
驗證 Bidirectional DShot GCR eRPM 回傳功能。QGC 無法正常解鎖（GPS/EKF 限制），需要讓馬達在 FC 未解鎖狀態下自動轉動，以測試 ESC_STATUS.rpm 是否能在 QGC 顯示。

### 解決方式
1. **新增 `DEBUG_FORCE_THROTTLE` 機制**（`Inc/targets.h`、`Src/dshot.c`）：在 `NUCLEO_L432KC_L431` target 加入 `#define DEBUG_FORCE_THROTTLE 400`，dshot.c 的 `tocheck==0`（FC 送停止）處，若 `armed==1` 則改送 `newinput=400`（20% 油門）。`armed==0` 時維持 `newinput=0` 讓 ARM 序列正常完成。
2. **測試結果**：QGC MAVLink Inspector → ESC_STATUS.rpm 成功顯示 `2785`，確認 Bidir DShot GCR eRPM 回傳功能正常運作。
3. **還原**：測試完成後移除 `DEBUG_FORCE_THROTTLE` define 及 dshot.c 對應條件碼，恢復正常 DShot 輸入處理。

### 補充觀察
- 馬達斷電後 QGC 仍短暫顯示舊 RPM：屬正常行為，sensorless ESC 需等 `bemf_timeout_happened` 超閾值才偵測到停止（約數百 ms 延遲）。
- `advance_level=18`（temp_advance=8，7.5° 固定超前角）在 13000 RPM 以下穩定，AM32 的固定超前角本身即按比例縮放（advance = commutation_interval × temp_advance / 64），不同轉速角度恆定。

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

## 2026-03-13（十）

### 修改原因
Live Watch 截圖（油門恆定 36%）顯示 `commutation_interval` 在 309~674 之間劇烈跳動（2 倍變化），而 `old_routine` 全程為 0（中斷模式），desync_happened 持續增加。

**根本原因：`advance_level = 0xFF` → `temp_advance = 16` → BEMF 偵測視窗太窄**

`0xFF > 42` 命中舊有安全檢查，設 `temp_advance = 16`：
```c
advance   = commutation_interval * 16/64 = commutation_interval/4
waitTime  = commutation_interval/2 - commutation_interval/4 = commutation_interval/4
```
在 36% 油門 commutation_interval ≈ 322 時：
- `waitTime = 80 counts`（BEMF 偵測視窗僅 80 counts，遠小於理論最大值 161 counts）
- 視窗縮短 → 換相後 PWM 振鈴雜訊直接進入 `interruptRoutine()` filter_level 判斷
- 雜訊偶爾通過 filter（filter_level ≈ 6 次確認）→ false zero-crossing
- `thiszctime` 記錄錯誤時間點 → `waitTime` 計算偏移 → 下次換相時序突變
- `average_interval` 跳動 > 50% → desync 觸發 → running=0 → 重啟循環

反觀 66% 油門時 commutation_interval ≈ 252，BEMF 幅度更大，信噪比改善，偵測反而更穩定。

**注意**：L4A 硬體沒有 g071 的 TIM1 OC4/OC5 comparator 硬體遮蔽，全靠 `filter_level` 軟體過濾，視窗窄時特別脆弱。

### 解決方式
在 `loadEEpromSettings()` 的 advance_level 現有安全檢查之前加入 0xFF 明確攔截：
- `advance_level == 0xFF` → 設為 18（`temp_advance = 18-10 = 8`，7.5° 超前角）
- `advance = commutation_interval * 8/64 = commutation_interval/8`
- `waitTime = commutation_interval/2 - commutation_interval/8 = 3/8 * commutation_interval`
- 選 18 而非 10（零超前角）：14 極馬達在 13000 RPM 附近實測以 14 失速，18=7.5° 為合理初值，兼顧 BEMF 視窗與換相效率
- 後續如需調整超前角，使用 AM32 Configurator 設定 advance_level 10~42

---

## 2026-03-16（二）

### 修改原因
全面審查 EEPROM 預設值，補足遺漏的 0xFF 安全攔截，確保所有影響多旋翼行為的欄位在 EEPROM 未初始化時都有安全預設值。同時修正 `filter_level` 最小值以提升高速 BEMF 雜訊過濾能力。

### 解決方式（`Src/main.c` `loadEEpromSettings()` 及主迴圈）

**新增 0xFF 安全攔截（多旋翼導向）：**

1. `dir_reversed == 0xFF` → 設為 0（預設正轉，0xFF 為 truthy 可能影響換相方向邏輯）
2. `variable_pwm == 0xFF` → 設為 0（預設固定 PWM，0xFF 不等於任何有效值 0/1/2，設為 0 避免未定義行為）
3. `telemetry_on_interval == 0xFF` → 設為 0（預設關閉週期遙測，DShot 模式使用 GCR eRPM 回傳，不需要 UART 週期遙測；0xFF → 每 255×1.1ms ≈ 284ms 發一次，浪費 CPU）
4. `motor_kv == 0xFF` → `motor_kv = 2300`（從舊值 2000 更新為實際馬達 MT2204-2300KV），`low_rpm_throttle_limit = 0`（電源供應器已限流，停用低轉速功率保護）

**`advance_level` 調整：**
- 初次修正設為 18（7.5°），實測與 14（3.75°）效果相同，12000 RPM 以上仍然失速
- 非單調行為：7.5° 在高速時 BEMF 視窗縮短，反而不如 3.75°
- **最終設為 14**（temp_advance = 4，3.75°），目前最佳實測值

**`filter_level` 最小值修正（主迴圈 ≈ 第 2168 行）：**
```c
// 修改前
filter_level = map(average_interval, 100, 500, 3, 12);
// 修改後
filter_level = map(average_interval, 100, 500, 5, 12); // 最小值從 3 改為 5
```
高速時（average_interval 接近 100）filter_level 從 3 提升至 5，需要連續 5 次取樣確認才算有效零交叉，減少 PWM 切換雜訊造成假零交叉導致 desync。

---

## 2026-03-16（研究記錄）

### 主題：DShot 遙測 bit 與 Bidirectional DShot 協定的關係

**結論：遙測 bit（bit 4）與雙向協定無關**

DShot 幀結構（16-bit）：
```
[15:5] 11-bit 數值（0=停止, 1-47=指令, 48-2047=油門）
[4]    遙測請求 bit → 1 = 請求 ESC 透過 UART 回傳遙測封包
[3:0]  4-bit CRC
```

**AM32 如何判斷 Bidirectional DShot（`dshot.c` 第 89-97 行）：**
- 自動偵測，不靠遙測 bit
- 兩幀之間若 input pin 持續維持 HIGH 超過 100 次檢查 → `dshot_telemetry = 1`
- 這代表 FC 送出的是**反相訊號**（Bidirectional DShot 的特徵：idle LOW → pin HIGH）
- 一旦切換：CRC 驗證改用反相版本（`~checkCRC + 16`），且換相後自動回傳 GCR 編碼 eRPM

| 模式 | 訊號極性 | Pin 閒置狀態 | ESC 回傳 |
|------|---------|-------------|---------|
| 標準 DShot | 正相 | LOW | 無（或 UART 另外） |
| Bidirectional DShot | **反相** | **HIGH** | **GCR eRPM（同線）** |

**目前測試設定**（Pixhawk QGC：DShot 單向）：`dshot_telemetry = 0`，標準模式，無 eRPM 回傳。

---
