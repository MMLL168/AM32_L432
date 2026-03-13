/*
 * dshot.h
 *
 *  Created on: Apr. 22, 2020
 *      Author: Alka
 */

#include "main.h"

#ifndef INC_DSHOT_H_
#define INC_DSHOT_H_

void computeDshotDMA(void);
void make_dshot_package(uint16_t com_time);

extern void playInputTune(void);
extern void playInputTune2(void);
extern void playBeaconTune3(void);
extern void saveEEpromSettings(void);

extern uint16_t dshot_goodcounts;  // CRC 正確的幀計數
extern uint16_t dshot_badcounts;   // CRC 錯誤的幀計數
extern uint16_t dshot_raw_value;   // 最新幀的原始 11-bit 值
extern uint16_t dshot_frametime;   // 幀週期（timer ticks，可驗證 DSHOT600/300/150）
extern char dshot_telemetry;
extern char armed;
extern char dir_reversed;
extern char buffer_divider;
extern uint8_t last_dshot_command;
extern uint32_t commutation_interval;

// int e_com_time;

#endif /* INC_DSHOT_H_ */
