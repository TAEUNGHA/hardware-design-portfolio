/* USER CODE BEGIN Header */

/**

  ******************************************************************************

  * @file           : main.c

  * @brief          : Main program body

  ******************************************************************************

  * @attention

  *

  * Copyright (c) 2026 STMicroelectronics.

  * All rights reserved.

  *

  ******************************************************************************

  */

/* USER CODE END Header */
/* Includes ------------------------------------------------------------------*/
#include "main.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */

#include <stdio.h>
#include <stdlib.h>

/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
/* ===== ADC ===== */
#define ADC_CH_COUNT   2
#define MQ4_IDX        0
#define FLAME_IDX      1
#define VREF           3.3f
#define ADC_MAX        4095.0f

/* ===== MLX90614 ===== */
#define MLX90614_ADDR         (0x5A << 1)
#define MLX90614_REG_AMBIENT  0x06
#define MLX90614_REG_OBJECT   0x07

/* ===== HC-SR04 ===== */
#define HC_SR04_TIMEOUT_US    30000

/* ===== SERVO (2600=닫힘/9시, 1500=열림/12시) ===== */
#define SERVO_OPEN_US   1500
#define SERVO_CLOSE_US  2600
#define SERVO_MIN_US    1500
#define SERVO_MAX_US    2600

#define PRINT_PERIOD_MS 500

/* ===== 경보 핀 매핑 ===== */
#define BUZZER_PORT  BUZZER_GPIO_Port
#define BUZZER_PIN   BUZZER_Pin
#define LED_R_PORT   LED_RED_GPIO_Port
#define LED_R_PIN    LED_RED_Pin
#define LED_Y_PORT   LED_YELLOW_GPIO_Port
#define LED_Y_PIN    LED_YELLOW_Pin
#define LED_G_PORT   LED_GREEN_GPIO_Port
#define LED_G_PIN    LED_GREEN_Pin
#define ACT_ON       GPIO_PIN_SET     /* active-low이면 RESET */
#define ACT_OFF      GPIO_PIN_RESET

#define FLAME_ON_LEVEL  0             /* 불꽃 DO 극성(현재 버너는 잘 안 잡힘) */

/* ===== 가스 (절대 raw 임계 + 지속) ===== */
#define GAS_WARN_RAW     2100         /* 경고 (시작 상한 2000 위) */
#define GAS_DAN_RAW      2300         /* 위험 (실측 누출값) */
#define GAS_DAN_RAW_COOK 2700         /* 조리 중엔 둔감 */
#define GAS_DAN_HOLD     5            /* 위험은 연속 5틱(2.5s) 지속돼야 확정 */

/* ===== 온도 ===== */
#define DT_ON          15.0f       /* 이 이상이면 "버너 활성"(heat_on) — 가스임계 완화용 */
#define DT_DANGER      260.0f      /* 표면 과열(soft, WARN) */
#define TA_DANGER      70.0f       /* 주변온도 과열(hard) */
#define S_DRY          30.0f       /* 빈냄비 의심 기울기(soft) */

/* ===== 불꽃센서 (화재감지 전용 · 화구에서 떨어뜨려 배치 · 아날로그 상대) ===== */
#define FLAME_DROP     800         /* 부팅 기준선 대비 이만큼↓ 떨어지면 불꽃 */
#define FLAME_FIRE_CNT 6           /* 연속 6틱(약 3s) 지속돼야 화재 확정 */

/* ===== 점유(HC-SR04) ===== */
#define PRESENCE_CM_DEFAULT 100.0f  /* 기본 거리임계(런타임 g_presence_cm 초기값) */
#define PRESENCE_ON_TICKS 2       /* 가까움 연속 2틱이어야 "사람 있음" 인정(스파이크 방지) */

/* ===== 거리 임계값 보정 모드 (S_CALIB) =====
 * CALIB 버튼 → 5초 대기(사용자 화구 앞 이동) → 10초 측정 평균 → 임계값 채택.
 * 주의(CAUTION)·경보(ALERT)에서는 진입 불가. */
#define CALIB_BTN_PORT     GPIOC        /* ★ 보정 버튼 핀(.ioc GPIO 입력 풀업) */
#define CALIB_BTN_PIN      GPIO_PIN_5
#define CALIB_BTN_ACTIVE_LOW 1
#define CALIB_WAIT_MS      5000UL       /* 진입 후 대기(이동 시간) */
#define CALIB_MEAS_MS      10000UL      /* 측정 시간 */
#define CALIB_MARGIN_CM    20.0f        /* 측정 평균 + 여유 = 임계값(서 있는 위치보다 약간 멀리) */
#define CALIB_MIN_CM       20.0f        /* 임계값 하한 */
#define CALIB_MAX_CM       400.0f       /* 임계값 상한 */
#define CALIB_MIN_SAMPLES  3            /* 유효 샘플 최소(미만이면 보정 실패, 기존값 유지) */

/* ===== 타이머 =====
 * ***********************************************************************
 * *  [!] 아래는 디버그용 "단축값"이다. 디버깅이 끝나면 반드시 우측 주석의  *
 * *      실제 목표값으로 되돌릴 것. (경진대회/실사용 전 필수 체크리스트)   *
 * *********************************************************************** */
#define T_ABS_DEB_MS   3000UL      /* 이탈 확정 지속       · 실제 3000~8000 */
#define T_BASE_MS      60000UL     /* 기본 타이머(추후 가변) · 실제 15분 = 900000 */
#define T_CONFIRM_MS   10000UL     /* 문제(WARN) 유예       · 실제 30초 = 30000 */
#define T_CAP_SESSION_MS 300000UL  /* 절대 세션 상한        · 실제 2시간 = 7200000 */
#define T_WARMUP_MS    3000UL      /* 부팅 워밍업          · 실제 300초 = 300000 */
#define T_POSTCLOSE_MS 15000UL     /* 주의(관찰) 최소       · 실제 60초 = 60000 */
#define T_GASFAIL_MS   10000UL     /* 닫힘 실패 감시창 */
#define TOBJ_HIST_N    20

/* ===== 상태 안정화 (채터링 방지: 지속/체류 조건) ===== */
#define SOFT_ENTER_TICKS  3        /* 소프트 이상 연속 3틱(1.5s)이면 문제 진입 */
#define CLEAR_TICKS       3        /* 해소도 연속 3틱이어야 복귀 */
#define WARN_MIN_MS       3000UL   /* 문제 최소 체류(바로 튕겨나가기 방지) */
#define CAUTION_OK_TICKS  6        /* 주의→대기: 안정 연속 6틱(3s) */
#define ALERT_EASE_TICKS  10       /* 경보→주의: 완화 연속 10틱(5s) */

/* ===== 타이머콕: 엔코더 + I2C CLCD 설정 타이머 (v8) =====
 * 스텝: 1~10분(1분) → ~60분(10분) → ~9시간(60분). 개방 시 확정 → 만료 시 잠금. */
#define TSET_MIN_MIN   1
#define TSET_MAX_MIN   540         /* 9시간 */
#define TSET_DEFAULT   30

/* --- 엔코더: 타이머 Encoder Mode = TIM1 (PA8=CH1, PA9=CH2) --- *
 * ★ .ioc: TIM1을 Encoder Mode로. 초음파 ECHO는 PA8→PC4로 이동(라벨 HC_ECHO 유지). */
#define ENC_TIM               htim1        /* TIM1 엔코더 */
#define ENC_COUNTS_PER_DETENT 4            /* 1클릭당 카운트(보통 4, 어떤건 2). 방향 반대면 A/B swap */
#define ENC_SW_PORT           GPIOB        /* 엔코더 푸시 스위치 = PB12 */
#define ENC_SW_PIN            GPIO_PIN_12
#define ENC_SW_ACTIVE_LOW     1            /* 풀업+눌림=LOW면 1 */

/* --- I2C CLCD (PCF8574 백팩, HD44780 4비트) = I2C2 단독(MLX와 분리) --- *
 * ★ .ioc: I2C2 활성(SCL=PB10, SDA=PB11). FLAME_DO→PC2, MQ4_DO→PC3로 이동(라벨 유지).
 *   I2C2(PB10/11)는 5V 관용이라 CLCD 5V 구동 가능(MLX 버스와 분리라 안전). */
#define LCD_HI2C   hi2c2                    /* CLCD 전용 I2C2 */
#define LCD_ADDR   (0x27 << 1)             /* PCF8574 주소(보통 0x27, 간혹 0x3F) */
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
ADC_HandleTypeDef hadc1;
DMA_HandleTypeDef hdma_adc1;

I2C_HandleTypeDef hi2c1;
I2C_HandleTypeDef hi2c2;

TIM_HandleTypeDef htim1;
TIM_HandleTypeDef htim2;
TIM_HandleTypeDef htim3;

UART_HandleTypeDef huart2;

/* USER CODE BEGIN PV */
volatile uint16_t g_adc[ADC_CH_COUNT];
volatile uint32_t g_rx_count = 0;
volatile uint8_t  g_servo_changed = 0;
volatile uint16_t g_servo_us = SERVO_OPEN_US;

float g_mq4_r0 = 10.0f;
float g_hc_distance_cm = 0.0f;

volatile uint8_t g_confirm = 0;        /* 확인/해제 */
volatile uint8_t g_test_danger = 0;    /* 'x' 강제위험(테스트) */
volatile uint8_t g_open_request = 0;   /* 버튼: 열기 */
volatile uint8_t g_close_request = 0;  /* 버튼: 정상 닫기 */

volatile uint16_t g_set_minutes = TSET_DEFAULT;  /* 확정된 설정 시간(분) */
volatile uint16_t g_set_pending = TSET_DEFAULT;  /* 엔코더로 조절 중인 값(누르면 확정) */

volatile uint8_t  g_calib_request = 0;           /* CALIB 버튼: 거리 보정 진입 요청 */
float             g_presence_cm = PRESENCE_CM_DEFAULT;  /* 런타임 거리 임계값(보정으로 갱신) */

typedef enum { S_BOOT, S_IDLE, S_OPEN, S_WARN, S_CLOSE, S_CAUTION, S_ALERT, S_CALIB } fsm_state_t;
/* 문제(WARN) 진입 사유 */
typedef enum { WR_NONE, WR_SENSOR, WR_TIMER, WR_CAP } warn_reason_t;

typedef struct {
    fsm_state_t state;
    uint16_t gas_raw, gas_base, gas_rise; int16_t gas_step; uint8_t gas_hold;
    uint16_t flame_raw, flame_base; uint8_t flame_do, flame_detect;
    uint8_t temp_ok, heat_on; float tobj, ta, dT, slope;
    uint8_t dist_ok, present; float dist;
    uint8_t gas_warn, gas_danger, flameout_rawgas, fire, device_overheat, overheat, boil_dry, immediate_danger;
    uint8_t soft_n;              /* 동시 소프트 이상 개수(가스경고/과열/빈냄비) */
    uint8_t warn_reason;
    uint32_t remain_s, elapsed_s;
    uint16_t set_min; uint32_t set_remain_s;   /* 설정 시간 / 잔여(초) */
} tele_t;
tele_t g_tele;
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
static void MX_GPIO_Init(void);
static void MX_DMA_Init(void);
static void MX_USART2_UART_Init(void);
static void MX_ADC1_Init(void);
static void MX_I2C1_Init(void);
static void MX_TIM3_Init(void);
static void MX_TIM2_Init(void);
static void MX_TIM1_Init(void);
static void MX_I2C2_Init(void);
/* USER CODE BEGIN PFP */
int __io_putchar(int ch);
void Servo_SetPulse(uint16_t pulse_us);
void Servo_ApplyPulse(int32_t pulse_us);
void Servo_HandleChar(uint8_t c);
HAL_StatusTypeDef MLX90614_ReadTemp(uint8_t reg, float *temp_c);
void Delay_us(uint16_t us);
HAL_StatusTypeDef HC_SR04_ReadDistance(float *distance_cm);
void Alarm_On(void);
void Alarm_Off(void);
void Buzzer_Beep(uint16_t ms);
void LED_Show(fsm_state_t s);
void Notify(const char *m);
void Servo_Close_Valve(void);
void Servo_Open_Valve(void);
void Servo_Detach(void);
void Valve_UserOpen(void);
void Valve_UserClose(void);
const char* fsm_state_name(fsm_state_t s);
void FSM_Step(uint16_t gas_raw, uint8_t flame_do, uint16_t flame_raw,
              float tobj, float ta, uint8_t temp_ok, float dist_cm, uint8_t dist_ok);
void Tele_Print(void);
/* I2C CLCD + 엔코더 설정 타이머 */
void LCD_Init(void);
void LCD_Cmd(uint8_t c);
void LCD_Data(uint8_t d);
void LCD_Gotoxy(uint8_t col, uint8_t row);
void LCD_Puts(const char *s);
void LCD_UpdateStatus(void);
void Encoder_Init(void);
void Encoder_Poll(void);
void EncBtn_Poll(void);
/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */
int __io_putchar(int ch)
{
    HAL_UART_Transmit(&huart2, (uint8_t *)&ch, 1, HAL_MAX_DELAY);
    return ch;
}

void Servo_SetPulse(uint16_t pulse_us)
{
    __HAL_TIM_SET_COMPARE(&htim3, TIM_CHANNEL_1, pulse_us);
}
void Servo_ApplyPulse(int32_t pulse_us)
{
    if (pulse_us < SERVO_MIN_US) pulse_us = SERVO_MIN_US;
    if (pulse_us > SERVO_MAX_US) pulse_us = SERVO_MAX_US;
    g_servo_us = (uint16_t)pulse_us;
    Servo_SetPulse(g_servo_us);
    g_servo_changed = 1;
}

/* UART 수신: k=확인/해제, x=강제위험(테스트). 그 외 무시 */
void Servo_HandleChar(uint8_t c)
{
    switch (c) {
        case 'k': case 'K': g_confirm = 1; break;
        case 'x': case 'X': g_test_danger = 1; break;
        default: break;
    }
}

HAL_StatusTypeDef MLX90614_ReadTemp(uint8_t reg, float *temp_c)
{
    uint8_t data[3];
    HAL_StatusTypeDef st = HAL_I2C_Mem_Read(&hi2c1, MLX90614_ADDR, reg, I2C_MEMADD_SIZE_8BIT, data, 3, 100);
    if (st != HAL_OK) return st;
    uint16_t raw = ((uint16_t)data[1] << 8) | data[0];
    if (raw & 0x8000) return HAL_ERROR;
    *temp_c = ((float)raw * 0.02f) - 273.15f;
    return HAL_OK;
}

void Delay_us(uint16_t us)
{
    uint16_t s = (uint16_t)__HAL_TIM_GET_COUNTER(&htim2);
    while ((uint16_t)((uint16_t)__HAL_TIM_GET_COUNTER(&htim2) - s) < us) {}
}

HAL_StatusTypeDef HC_SR04_ReadDistance(float *distance_cm)
{
    uint16_t s, es, ee, pu;
    HAL_GPIO_WritePin(HC_TRIG_GPIO_Port, HC_TRIG_Pin, GPIO_PIN_RESET); Delay_us(2);
    HAL_GPIO_WritePin(HC_TRIG_GPIO_Port, HC_TRIG_Pin, GPIO_PIN_SET);   Delay_us(10);
    HAL_GPIO_WritePin(HC_TRIG_GPIO_Port, HC_TRIG_Pin, GPIO_PIN_RESET);
    s = (uint16_t)__HAL_TIM_GET_COUNTER(&htim2);
    while (HAL_GPIO_ReadPin(HC_ECHO_GPIO_Port, HC_ECHO_Pin) == GPIO_PIN_RESET)
        if ((uint16_t)((uint16_t)__HAL_TIM_GET_COUNTER(&htim2) - s) > HC_SR04_TIMEOUT_US) return HAL_TIMEOUT;
    es = (uint16_t)__HAL_TIM_GET_COUNTER(&htim2);
    while (HAL_GPIO_ReadPin(HC_ECHO_GPIO_Port, HC_ECHO_Pin) == GPIO_PIN_SET)
        if ((uint16_t)((uint16_t)__HAL_TIM_GET_COUNTER(&htim2) - es) > HC_SR04_TIMEOUT_US) return HAL_TIMEOUT;
    ee = (uint16_t)__HAL_TIM_GET_COUNTER(&htim2); pu = (uint16_t)(ee - es);
    *distance_cm = ((float)pu * 0.0343f) / 2.0f;
    return HAL_OK;
}

void Alarm_On(void)  { HAL_GPIO_WritePin(LED_R_PORT, LED_R_PIN, ACT_ON); }   /* 부저는 Buzzer_Beep로 */
void Alarm_Off(void) { HAL_GPIO_WritePin(BUZZER_PORT, BUZZER_PIN, ACT_OFF); HAL_GPIO_WritePin(LED_R_PORT, LED_R_PIN, ACT_OFF); }

/* 패시브 부저 2kHz 톤 */
void Buzzer_Beep(uint16_t ms)
{
    uint32_t s = HAL_GetTick();
    while (HAL_GetTick() - s < ms) {
        HAL_GPIO_WritePin(BUZZER_PORT, BUZZER_PIN, ACT_ON);  Delay_us(250);
        HAL_GPIO_WritePin(BUZZER_PORT, BUZZER_PIN, ACT_OFF); Delay_us(250);
    }
}

void LED_Show(fsm_state_t s)
{
    GPIO_PinState g = ACT_OFF, y = ACT_OFF, r = ACT_OFF;
    if (s == S_IDLE || s == S_OPEN)                 g = ACT_ON;
    else if (s == S_CALIB)                          { g = ACT_ON; y = ACT_ON; }  /* 보정 중 */
    else if (s == S_WARN || s == S_CAUTION)         y = ACT_ON;
    else if (s == S_CLOSE || s == S_ALERT)          r = ACT_ON;
    HAL_GPIO_WritePin(LED_G_PORT, LED_G_PIN, g);
    HAL_GPIO_WritePin(LED_Y_PORT, LED_Y_PIN, y);
    HAL_GPIO_WritePin(LED_R_PORT, LED_R_PIN, r);
}
void Notify(const char *m) { printf("[NOTIFY] %s\r\n", m); }

/* --- 서보: 닫을 때만 구동, 그 외 detach(신호 LOW) --- */
static void Servo_PinAF(void)
{
    GPIO_InitTypeDef g = {0};
    g.Pin = GPIO_PIN_6; g.Mode = GPIO_MODE_AF_PP; g.Pull = GPIO_NOPULL; g.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(GPIOA, &g);
}
void Servo_Detach(void)   /* 펄스 LOW 구간에서 정지(runt 방지) + 입력 풀다운 */
{
    uint32_t guard = 0;
    while (__HAL_TIM_GET_COUNTER(&htim3) < SERVO_CLOSE_US && ++guard < 200000) {}
    HAL_TIM_PWM_Stop(&htim3, TIM_CHANNEL_1);
    GPIO_InitTypeDef g = {0};
    g.Pin = GPIO_PIN_6; g.Mode = GPIO_MODE_INPUT; g.Pull = GPIO_PULLDOWN;
    HAL_GPIO_Init(GPIOA, &g);
}
void Servo_Close_Valve(void)
{
    Servo_PinAF();
    __HAL_TIM_SET_COMPARE(&htim3, TIM_CHANNEL_1, SERVO_CLOSE_US);
    HAL_TIM_PWM_Start(&htim3, TIM_CHANNEL_1);
    g_servo_us = SERVO_CLOSE_US; g_servo_changed = 1;
    HAL_Delay(800);
    Servo_Detach();
}
void Servo_Open_Valve(void)
{
    Servo_PinAF();
    __HAL_TIM_SET_COMPARE(&htim3, TIM_CHANNEL_1, SERVO_OPEN_US);
    HAL_TIM_PWM_Start(&htim3, TIM_CHANNEL_1);
    g_servo_us = SERVO_OPEN_US; g_servo_changed = 1;
    HAL_Delay(800);
    Servo_Detach();
}

const char* fsm_state_name(fsm_state_t s)
{
    switch (s) {
        case S_BOOT: return "BOOT"; case S_IDLE: return "IDLE"; case S_OPEN: return "OPEN";
        case S_WARN: return "WARN"; case S_CLOSE: return "CLOSE";
        case S_CAUTION: return "CAUTION"; case S_ALERT: return "ALERT";
        case S_CALIB: return "CALIB"; default: return "?";
    }
}

static fsm_state_t g_state = S_BOOT;
static uint16_t gas_base = 0, gas_prev = 0, gas_at_close = 0;
static uint16_t flame_base = 0; static uint8_t flame_base_set = 0;
static uint8_t  gas_base_set = 0, heat_prev = 0;
static uint32_t heat_off_ms = 0;
static float    tobj_hist[TOBJ_HIST_N];
static uint8_t  tobj_idx = 0, tobj_fill = 0;
static uint32_t t_session_start = 0, t_deadline = 0, t_state_enter = 0, t_present_last = 0, t_close_done = 0;
static uint32_t g_set_ms_latched = 0;   /* 개방 시 확정된 설정시간(ms) */
static uint8_t  present = 0, close_reason_alarm = 0, near_cnt = 0;
static uint8_t  soft_cnt = 0, clr_cnt = 0, cau_cnt = 0, alert_ease_cnt = 0, comp_cnt = 0;
static warn_reason_t warn_reason = WR_NONE;
static float    calib_sum = 0.0f; static uint16_t calib_cnt = 0;   /* 거리 보정 누적 */

static void fsm_goto(fsm_state_t s, const char *name)
{
    g_state = s; t_state_enter = HAL_GetTick(); LED_Show(s);
    printf("[FSM] -> %s\r\n", name);
}
static float tobj_slope(float v)   /* ℃/min (10초 전 대비) */
{
    tobj_hist[tobj_idx] = v;
    tobj_idx = (uint8_t)((tobj_idx + 1) % TOBJ_HIST_N);
    if (tobj_fill < TOBJ_HIST_N) { tobj_fill++; return 0.0f; }
    return (v - tobj_hist[tobj_idx]) * 6.0f;
}

/* 버튼: 사용자 개방 / 정상 닫기 */
void Valve_UserOpen(void)
{
    Alarm_Off();
    Servo_Open_Valve();
    t_session_start = HAL_GetTick();
    g_set_ms_latched = (uint32_t)g_set_minutes * 60000UL;   /* 설정시간 확정(래치) */
    t_deadline = t_session_start + T_BASE_MS;
    soft_cnt = 0; clr_cnt = 0; comp_cnt = 0; near_cnt = 0; warn_reason = WR_NONE;
    fsm_goto(S_OPEN, "OPEN(btn)");
}
void Valve_UserClose(void)
{
    Servo_Close_Valve();
    Alarm_Off();
    t_session_start = 0; g_set_ms_latched = 0; t_deadline = HAL_GetTick();
    near_cnt = 0; soft_cnt = 0; comp_cnt = 0;
    fsm_goto(S_IDLE, "IDLE(btn close)");
}

void FSM_Step(uint16_t gas_raw, uint8_t flame_do, uint16_t flame_raw,
              float tobj, float ta, uint8_t temp_ok, float dist_cm, uint8_t dist_ok)
{
    uint32_t now = HAL_GetTick();

    if (!gas_base_set && now > 2000) { gas_base = gas_raw; gas_base_set = 1; }
    uint16_t gas_rise = (gas_raw > gas_base) ? (uint16_t)(gas_raw - gas_base) : 0;
    int32_t  gas_step = (int32_t)gas_raw - (int32_t)gas_prev; gas_prev = gas_raw;

    /* 불꽃센서: 화재감지 전용(아날로그 상대). 부팅 기준선 대비 크게↓ = 불꽃 */
    if (!flame_base_set && now > 2000) { flame_base = flame_raw; flame_base_set = 1; }
    uint8_t flame_detect = (flame_base_set && (flame_raw + FLAME_DROP < flame_base)) ? 1 : 0;

    /* Tobj 저역통과(노이즈 스파이크 억제) */
    static float tobj_f = 0.0f; static uint8_t tobj_f_init = 0;
    if (temp_ok) { if (!tobj_f_init) { tobj_f = tobj; tobj_f_init = 1; } else tobj_f = tobj_f*0.7f + tobj*0.3f; }
    float dT = temp_ok ? (tobj_f - ta) : 0.0f;
    float slope = temp_ok ? tobj_slope(tobj_f) : 0.0f;

    uint8_t heat_on = (temp_ok && dT > DT_ON) ? 1 : 0;   /* 표면이 뜨거움 = 버너 활성(가스임계 완화용) */
    if (heat_prev == 1 && heat_on == 0) heat_off_ms = now;
    uint8_t cooking = heat_on;                      /* 상태 아닌 온도(heat_on)로만 조리 판단 */

    /* 감지도 지속 조건(연속 N틱)이어야 인정 — 단발 스파이크로 타이머 리셋 방지 */
    uint8_t near_now = (dist_ok && dist_cm < g_presence_cm) ? 1 : 0;
    if (near_now) { if (near_cnt < 255) near_cnt++; } else near_cnt = 0;
    if (near_cnt >= PRESENCE_ON_TICKS) { t_present_last = now; present = 1; }  /* 지속 감지만 present */
    else if (now - t_present_last > T_ABS_DEB_MS) present = 0;                  /* 이탈은 기존 디바운스 */

    /* --- 화재/과열 (기울기 기반 오경보 원인 제거: 불꽃센서+주변온도만) --- */
    uint8_t device_overheat = (temp_ok && ta > TA_DANGER && ta < 150.0f);  /* 주변온도 과열(hard) */
    static uint8_t fire_cnt = 0;
    if (flame_detect) { if (fire_cnt < 255) fire_cnt++; } else fire_cnt = 0;
    uint8_t fire = (fire_cnt >= FLAME_FIRE_CNT) || device_overheat;         /* 불꽃(지속) 또는 주변과열 */
    uint8_t overheat = (temp_ok && dT > DT_DANGER);                         /* 표면 과열(soft) */

    /* --- 가스 (heat_on이면 조리로 보고 임계 완화) --- */
    uint16_t dan = cooking ? GAS_DAN_RAW_COOK : GAS_DAN_RAW;
    uint8_t gas_warn = (gas_raw > GAS_WARN_RAW);
    static uint8_t gas_hi_cnt = 0;
    if (gas_raw > dan) { if (gas_hi_cnt < 255) gas_hi_cnt++; } else gas_hi_cnt = 0;
    uint8_t gas_danger = (gas_hi_cnt >= GAS_DAN_HOLD);

    /* 플레임아웃: 가열되다 꺼진 직후 가스 잔존(미연소 누출) */
    uint8_t flameout_rawgas = (heat_on == 0) && (heat_off_ms != 0) &&
                              (now - heat_off_ms < 30000UL) && (gas_raw > GAS_WARN_RAW) && (slope <= 0.0f);
    uint8_t immediate_danger = gas_danger || flameout_rawgas || fire || device_overheat;
    if (g_test_danger) { immediate_danger = 1; g_test_danger = 0; }
    uint8_t boil_dry = (!present) && (slope > S_DRY);
    heat_prev = heat_on;

    /* 동시 소프트 이상 개수(우선순위 판단용): 가스경고 / 표면과열 / 빈냄비 */
    uint8_t soft_n = (uint8_t)((gas_warn?1:0) + (overheat?1:0) + (boil_dry?1:0));

    /* 텔레메트리 */
    g_tele.state=g_state; g_tele.gas_raw=gas_raw; g_tele.gas_base=gas_base; g_tele.gas_rise=gas_rise;
    g_tele.gas_step=(int16_t)gas_step; g_tele.gas_hold=gas_hi_cnt;
    g_tele.flame_raw=flame_raw; g_tele.flame_base=flame_base; g_tele.flame_do=flame_do; g_tele.flame_detect=flame_detect;
    g_tele.temp_ok=temp_ok; g_tele.heat_on=heat_on; g_tele.tobj=tobj_f; g_tele.ta=ta; g_tele.dT=dT; g_tele.slope=slope;
    g_tele.dist_ok=dist_ok; g_tele.dist=dist_cm; g_tele.present=present;
    g_tele.gas_warn=gas_warn; g_tele.gas_danger=gas_danger; g_tele.flameout_rawgas=flameout_rawgas;
    g_tele.fire=fire; g_tele.device_overheat=device_overheat; g_tele.overheat=overheat;
    g_tele.boil_dry=boil_dry; g_tele.immediate_danger=immediate_danger;
    g_tele.soft_n=soft_n;
    g_tele.warn_reason=(uint8_t)warn_reason;
    g_tele.remain_s=(t_deadline>now)?((t_deadline-now)/1000):0;
    g_tele.elapsed_s=(t_session_start && now>=t_session_start)?((now-t_session_start)/1000):0;
    g_tele.set_min=g_set_minutes;
    g_tele.set_remain_s=(t_session_start && g_set_ms_latched && now < t_session_start+g_set_ms_latched)
                        ? ((t_session_start+g_set_ms_latched-now)/1000) : 0;

    /* 거리 보정 진입: 주의·경보(및 부팅/닫힘 전이) 아닐 때만, 위험 없을 때만 */
    if (g_calib_request) {
        g_calib_request = 0;
        if ((g_state == S_IDLE || g_state == S_OPEN || g_state == S_WARN) && !immediate_danger) {
            Servo_Close_Valve();               /* 안전: 보정 중 밸브 닫힘 */
            Alarm_Off();
            calib_sum = 0.0f; calib_cnt = 0;
            t_session_start = 0; g_set_ms_latched = 0; t_deadline = now;
            warn_reason = WR_NONE;
            fsm_goto(S_CALIB, "CALIB(enter)");
            return;
        }
    }

    switch (g_state)
    {
    case S_BOOT:
        if (now - t_state_enter > T_WARMUP_MS) { gas_base = gas_raw; gas_base_set = 1; fsm_goto(S_IDLE, "IDLE"); }
        return;

    case S_IDLE:   /* 닫힘: 버튼=열기, 가스=누출경보 */
        if (gas_rise == 0 && gas_raw < gas_base) gas_base = gas_raw;
        if (g_open_request) { g_open_request = 0; Valve_UserOpen(); return; }
        if (immediate_danger) { close_reason_alarm = 1; fsm_goto(S_CLOSE, "CLOSE(leak)"); return; }
        return;

    case S_OPEN:   /* 밸브 열림: 타이머 + 센서 감시 (조리여부는 상태 아님) */
        /* 하드 위험 → 즉시 닫기+경보 */
        if (immediate_danger) { close_reason_alarm = 1; fsm_goto(S_CLOSE, "CLOSE(danger)"); return; }
        /* 사용자 버튼 정상 닫기 */
        if (g_close_request) { g_close_request = 0; Valve_UserClose(); return; }
        /* 타이머: 사람 있으면 갱신(만료 안 됨), 없으면 카운트다운 */
        if (present) t_deadline = now + T_BASE_MS;
        /* 소프트 이상: 우선순위 = (하드는 위에서 처리) 복합(2개↑) > 단일 */
        {
            if (soft_n >= 1) { if (soft_cnt < 255) soft_cnt++; } else soft_cnt = 0;
            if (soft_n >= 2) { if (comp_cnt < 255) comp_cnt++; } else comp_cnt = 0;
            /* 복합(소프트 2개 이상 동시 지속) → 위험 준함: 경보 닫기 */
            if (comp_cnt >= SOFT_ENTER_TICKS) { close_reason_alarm = 1; fsm_goto(S_CLOSE, "CLOSE(compound)"); return; }
            /* 단일 소프트 지속 → 완충(WARN, 무경보) */
            if (soft_cnt >= SOFT_ENTER_TICKS) { warn_reason = WR_SENSOR; fsm_goto(S_WARN, "WARN(sensor)"); return; }
        }
        /* 설정 시간(엔코더) 만료 → 문제 → 무조건 잠금 */
        if (now - t_session_start > g_set_ms_latched) { warn_reason = WR_CAP; fsm_goto(S_WARN, "WARN(settime)"); return; }
        /* 타이머 만료(이탈이 그만큼 지속) → 문제(2중 안전) */
        if (now >= t_deadline) { warn_reason = WR_TIMER; fsm_goto(S_WARN, "WARN(timer/absent)"); return; }
        return;

    case S_WARN:   /* 문제(2중 안전 완충): 복귀=열림, 유예초과=무경보 닫기 */
        if (immediate_danger) { close_reason_alarm = 1; fsm_goto(S_CLOSE, "CLOSE(danger)"); return; }
        /* WARN 중 두 번째 소프트가 겹치면(복합) → 경보 닫기로 격상 */
        if (soft_n >= 2) { if (comp_cnt < 255) comp_cnt++; } else comp_cnt = 0;
        if (comp_cnt >= SOFT_ENTER_TICKS) { close_reason_alarm = 1; fsm_goto(S_CLOSE, "CLOSE(compound)"); return; }
        /* 사유별 해소 판정 */
        {
            uint8_t soft_clear = (!gas_warn && !overheat && !boil_dry);
            uint8_t clear_now;
            switch (warn_reason) {
                case WR_TIMER:    clear_now = present; break;              /* 이탈: 사람 복귀 */
                case WR_SENSOR:   clear_now = (present && soft_clear); break;
                default:          clear_now = 0; break;                   /* WR_CAP: 해소 없음 */
            }
            if (clear_now) { if (clr_cnt < 255) clr_cnt++; } else clr_cnt = 0;
            if (clr_cnt >= CLEAR_TICKS && (now - t_state_enter > WARN_MIN_MS)) {
                t_deadline = now + T_BASE_MS; warn_reason = WR_NONE;
                soft_cnt = 0; comp_cnt = 0;
                fsm_goto(S_OPEN, "OPEN(clear)"); return;
            }
        }
        /* 사용자 확인 → 열림 복귀(설정시간도 현재값으로 재시작 = 연장) */
        if (g_confirm) {
            g_confirm = 0;
            t_session_start = now; g_set_ms_latched = (uint32_t)g_set_minutes * 60000UL;
            t_deadline = now + T_BASE_MS; warn_reason = WR_NONE;
            soft_cnt = 0; comp_cnt = 0;
            fsm_goto(S_OPEN, "OPEN(confirm)"); return;
        }
        /* 유예시간 경과 → 무경보 닫기 */
        if (now - t_state_enter > T_CONFIRM_MS) { close_reason_alarm = 0; fsm_goto(S_CLOSE, "CLOSE(warn-timeout)"); return; }
        return;

    case S_CLOSE:
        Servo_Close_Valve(); gas_at_close = gas_raw; t_close_done = HAL_GetTick();
        cau_cnt = 0;
        /* 닫힘: 열림 타이머·이탈 카운트는 무의미 → 초기화(remain 0으로) */
        t_session_start = 0; g_set_ms_latched = 0; t_deadline = now;
        near_cnt = 0; soft_cnt = 0; comp_cnt = 0;
        if (close_reason_alarm) { Alarm_On(); Notify("danger cut"); alert_ease_cnt = 0; fsm_goto(S_ALERT, "ALERT"); }
        else                    { fsm_goto(S_CAUTION, "CAUTION"); }
        return;

    case S_CAUTION:   /* 주의: 닫은 뒤 관찰(개방 불가). 악화→경보, 안정 지속→대기 */
        /* 닫힘 실패(가스 재상승) → 경보 */
        if ((now - t_close_done < T_GASFAIL_MS) && (gas_raw > gas_at_close + 400)) { Alarm_On(); Notify("close-fail"); alert_ease_cnt = 0; fsm_goto(S_ALERT, "ALERT(closefail)"); return; }
        /* 악화(하드 위험/과열) → 경보 */
        if (immediate_danger || overheat) { Alarm_On(); alert_ease_cnt = 0; fsm_goto(S_ALERT, "ALERT(escalate)"); return; }
        /* 안정 지속 → 대기 회복 */
        {
            uint8_t ok = (!gas_warn && !overheat && gas_raw < GAS_WARN_RAW);
            if (ok) { if (cau_cnt < 255) cau_cnt++; } else cau_cnt = 0;
            if (cau_cnt >= CAUTION_OK_TICKS && (now - t_state_enter > T_POSTCLOSE_MS)) { warn_reason = WR_NONE; Notify("recovered"); fsm_goto(S_IDLE, "IDLE"); return; }
        }
        return;

    case S_ALERT:   /* 경보(최악): 개방 불가. 위험 완화 지속 → 주의로 하강(2단계 회복), 또는 버튼 확인 */
    {
        uint8_t danger_gone = (!immediate_danger) && (!overheat);
        /* 위험 완화(가스가 경고 아래로) 지속 → 주의로 하강 */
        uint8_t easing = danger_gone && (gas_raw < GAS_WARN_RAW);
        if (easing) { if (alert_ease_cnt < 255) alert_ease_cnt++; } else alert_ease_cnt = 0;
        if (alert_ease_cnt >= ALERT_EASE_TICKS) {
            Alarm_Off(); Notify("easing -> caution");
            gas_at_close = gas_raw; t_close_done = now; cau_cnt = 0;
            fsm_goto(S_CAUTION, "CAUTION(from alert)"); return;
        }
        /* 수동 확인 + 완전 해소 → 대기 직행 */
        if (g_confirm && easing) { g_confirm = 0; Alarm_Off(); Notify("cleared"); fsm_goto(S_IDLE, "IDLE"); return; }
        if (g_confirm) g_confirm = 0;   /* 위험 남아있으면 확인 무시(플래그만 소모) */
        return;
    }

    case S_CALIB:   /* 거리 임계값 보정: 5초 대기 → 10초 측정 평균 → 임계값 채택 */
    {
        uint32_t el = now - t_state_enter;
        /* 보정 중에도 하드 위험은 감시 → 즉시 중단하고 닫기+경보 */
        if (immediate_danger) { close_reason_alarm = 1; fsm_goto(S_CLOSE, "CLOSE(danger)"); return; }

        if (el < CALIB_WAIT_MS) {
            /* 대기: 사용자 화구 앞으로 이동 */
        } else if (el < CALIB_WAIT_MS + CALIB_MEAS_MS) {
            /* 측정: 유효 거리 샘플 누적(비정상 값 제외) */
            if (dist_ok && dist_cm > 2.0f && dist_cm < CALIB_MAX_CM) { calib_sum += dist_cm; calib_cnt++; }
        } else {
            /* 완료: 평균 → 여유 가산 → 임계값 채택 */
            if (calib_cnt >= CALIB_MIN_SAMPLES) {
                float th = (calib_sum / (float)calib_cnt) + CALIB_MARGIN_CM;
                if (th < CALIB_MIN_CM) th = CALIB_MIN_CM;
                if (th > CALIB_MAX_CM) th = CALIB_MAX_CM;
                g_presence_cm = th;
                printf("[CALIB] samples=%u avg=%.1f -> presence=%.1fcm\r\n",
                       calib_cnt, calib_sum/(float)calib_cnt, g_presence_cm);
                Notify("presence calibrated");
            } else {
                Notify("calib failed (few samples, keep old)");
            }
            fsm_goto(S_IDLE, "IDLE(calib done)");
        }
        return;
    }
    }
}

void Tele_Print(void)
{
    printf("\r\n[T=%lus] STATE=%s  servo=%uus rx=%lu\r\n",
        (unsigned long)g_tele.elapsed_s, fsm_state_name(g_tele.state), (unsigned)g_servo_us, (unsigned long)g_rx_count);
    printf(" GAS raw=%u base=%u rise=%u hold=%u | WARN>%d DAN>%d(cook>%d)\r\n",
        g_tele.gas_raw, g_tele.gas_base, g_tele.gas_rise, g_tele.gas_hold, GAS_WARN_RAW, GAS_DAN_RAW, GAS_DAN_RAW_COOK);
    printf(" FLM raw=%u base=%u det=%u | TMP ok=%u heat=%u Tobj=%.1f Ta=%.1f dT=%.1f slope=%.1f/min\r\n",
        g_tele.flame_raw, g_tele.flame_base, g_tele.flame_detect,
        g_tele.temp_ok, g_tele.heat_on, g_tele.tobj, g_tele.ta, g_tele.dT, g_tele.slope);
    printf(" DIST ok=%u %.1fcm present=%u(th%.0f) | setMin=%u setRemain=%lus absRemain=%lus wR=%u(0N/1sen/2tmr/3set)\r\n",
        g_tele.dist_ok, g_tele.dist, g_tele.present, g_presence_cm, g_tele.set_min,
        (unsigned long)g_tele.set_remain_s, (unsigned long)g_tele.remain_s, g_tele.warn_reason);
    printf(" EV gasW=%u gasD=%u flmOut=%u fire=%u devOH=%u OH=%u dry=%u softN=%u IMM=%u\r\n",
        g_tele.gas_warn, g_tele.gas_danger, g_tele.flameout_rawgas, g_tele.fire,
        g_tele.device_overheat, g_tele.overheat, g_tele.boil_dry, g_tele.soft_n, g_tele.immediate_danger);
    printf("------------------------------------------\r\n");
}

/* ================= I2C CLCD (PCF8574 백팩, HD44780 4비트) ================= */
#define LCD_BL 0x08   /* 백라이트 on 비트 */
static void lcd_i2c(uint8_t b){ HAL_I2C_Master_Transmit(&LCD_HI2C, LCD_ADDR, &b, 1, 50); }
static void lcd_strobe(uint8_t d){ lcd_i2c((uint8_t)(d|0x04|LCD_BL)); Delay_us(1);
                                   lcd_i2c((uint8_t)((d&~0x04)|LCD_BL)); Delay_us(50); }
static void lcd_write4(uint8_t hi_nibble, uint8_t rs){ lcd_strobe((uint8_t)((hi_nibble&0xF0)|(rs?0x01:0x00))); }
static void lcd_send(uint8_t val, uint8_t rs){ lcd_write4((uint8_t)(val&0xF0), rs); lcd_write4((uint8_t)(val<<4), rs); }
void LCD_Cmd(uint8_t c){ lcd_send(c,0); if (c==0x01||c==0x02) HAL_Delay(2); }
void LCD_Data(uint8_t d){ lcd_send(d,1); }
void LCD_Gotoxy(uint8_t col,uint8_t row){ LCD_Cmd((uint8_t)(0x80 | ((row?0x40:0x00)+col))); }
void LCD_Puts(const char*s){ while(*s) LCD_Data((uint8_t)*s++); }
void LCD_Init(void){
    HAL_Delay(50);
    lcd_write4(0x30,0); HAL_Delay(5);
    lcd_write4(0x30,0); Delay_us(150);
    lcd_write4(0x30,0); Delay_us(150);
    lcd_write4(0x20,0); Delay_us(150);   /* 4비트 진입 */
    LCD_Cmd(0x28); LCD_Cmd(0x08); LCD_Cmd(0x01); HAL_Delay(2); LCD_Cmd(0x06); LCD_Cmd(0x0C);
}

/* ================= 엔코더 설정 타이머 ================= */
/* 스텝 규칙: 1~10분(1분) → ~60분(10분) → ~9시간(60분) */
static uint16_t tset_next(uint16_t m){
    uint16_t n = (m < 10) ? (uint16_t)(m+1) : (m < 60) ? (uint16_t)(m+10) : (uint16_t)(m+60);
    if (n > TSET_MAX_MIN) n = TSET_MAX_MIN;
    return n;
}
static uint16_t tset_prev(uint16_t m){
    uint16_t n = (m <= 10) ? (uint16_t)(m-1) : (m <= 60) ? (uint16_t)(m-10) : (uint16_t)(m-60);
    if (n < TSET_MIN_MIN || m <= TSET_MIN_MIN) n = TSET_MIN_MIN;
    return n;
}
void Encoder_Init(void){
    HAL_TIM_Encoder_Start(&ENC_TIM, TIM_CHANNEL_ALL);
    __HAL_TIM_SET_COUNTER(&ENC_TIM, 0);
    g_set_minutes = TSET_DEFAULT; g_set_pending = TSET_DEFAULT;
}
/* 엔코더 회전 → g_set_pending 갱신 (대기 상태에서만) */
void Encoder_Poll(void){
    static int32_t accum = 0; static uint16_t last = 0;
    uint16_t cnt = (uint16_t)__HAL_TIM_GET_COUNTER(&ENC_TIM);
    int16_t d = (int16_t)(cnt - last); last = cnt;
    if (g_tele.state != S_IDLE) { accum = 0; return; }   /* 열림 중 조절 금지 */
    if (d == 0) return;
    accum += d;
    while (accum >=  ENC_COUNTS_PER_DETENT){ accum -= ENC_COUNTS_PER_DETENT; g_set_pending = tset_next(g_set_pending); }
    while (accum <= -ENC_COUNTS_PER_DETENT){ accum += ENC_COUNTS_PER_DETENT; g_set_pending = tset_prev(g_set_pending); }
}
/* 엔코더 푸시 = 설정 확정(대기 상태). 개방은 PB9가 담당 */
void EncBtn_Poll(void){
    static uint8_t prev = 0; static uint32_t t_last = 0;   /* prev=이전 눌림상태(0=뗌) */
    uint8_t raw = (uint8_t)HAL_GPIO_ReadPin(ENC_SW_PORT, ENC_SW_PIN);
    uint8_t pressed = ENC_SW_ACTIVE_LOW ? (raw==0) : (raw==1);
    uint32_t now = HAL_GetTick();
    if (prev==0 && pressed && (now - t_last) > 200) {   /* 뗌→눌림 에지 */
        t_last = now;
        if (g_tele.state == S_IDLE) { g_set_minutes = g_set_pending; Notify("time set"); }
    }
    prev = pressed;
}

/* ================= 16x2 상태 표시 ================= */
static void fmt_time(uint16_t m, char*buf, int n){
    if (m < 60) snprintf(buf,(size_t)n,"%u min",(unsigned)m);
    else        snprintf(buf,(size_t)n,"%u h",(unsigned)(m/60));
}
void LCD_UpdateStatus(void){
    char t[12], l0[24], l1[24];
    if (g_tele.state==S_CALIB){
        uint32_t el = HAL_GetTick() - t_state_enter;
        if (el < CALIB_WAIT_MS){
            snprintf(l0,sizeof l0,"CALIB: stand at ");
            snprintf(l1,sizeof l1,"burner   %lus   ", (unsigned long)((CALIB_WAIT_MS-el)/1000+1));
        } else if (el < CALIB_WAIT_MS+CALIB_MEAS_MS){
            snprintf(l0,sizeof l0,"MEASURING...    ");
            snprintf(l1,sizeof l1,"hold     %lus   ", (unsigned long)((CALIB_WAIT_MS+CALIB_MEAS_MS-el)/1000+1));
        } else {
            snprintf(l0,sizeof l0,"CALIB done      ");
            snprintf(l1,sizeof l1,"th = %-3.0f cm    ", g_presence_cm);
        }
    } else if (g_tele.state==S_IDLE || g_tele.state==S_BOOT){
        fmt_time(g_set_pending, t, sizeof t);
        snprintf(l0,sizeof l0,"SET %-12s", t);
        if (g_set_pending==g_set_minutes) snprintf(l1,sizeof l1,"OK  open=BTN    ");
        else                              snprintf(l1,sizeof l1,"turn&push set   ");
    } else if (g_tele.state==S_OPEN || g_tele.state==S_WARN){
        uint32_t r=g_tele.set_remain_s;
        snprintf(l0,sizeof l0,"OPEN %02lu:%02lu:%02lu  ",
                 (unsigned long)(r/3600),(unsigned long)((r%3600)/60),(unsigned long)(r%60));
        snprintf(l1,sizeof l1,"%-12s P%c ", fsm_state_name(g_tele.state), g_tele.present?'Y':'N');
    } else {
        snprintf(l0,sizeof l0,"%-16s",(g_tele.state==S_ALERT)?"!!  ALARM  !!":"CLOSED");
        snprintf(l1,sizeof l1,"%-16s", fsm_state_name(g_tele.state));
    }
    LCD_Gotoxy(0,0); LCD_Puts(l0);
    LCD_Gotoxy(0,1); LCD_Puts(l1);
}
/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{

  /* USER CODE BEGIN 1 */

  /* USER CODE END 1 */

  /* MCU Configuration--------------------------------------------------------*/

  /* Reset of all peripherals, Initializes the Flash interface and the Systick. */
  HAL_Init();

  /* USER CODE BEGIN Init */

  /* USER CODE END Init */

  /* Configure the system clock */
  SystemClock_Config();

  /* USER CODE BEGIN SysInit */

  /* USER CODE END SysInit */

  /* Initialize all configured peripherals */
  MX_GPIO_Init();
  MX_DMA_Init();
  MX_USART2_UART_Init();
  MX_ADC1_Init();
  MX_I2C1_Init();
  MX_TIM3_Init();
  MX_TIM2_Init();
  MX_TIM1_Init();
  MX_I2C2_Init();
  /* USER CODE BEGIN 2 */
  /* PA3(USART2_RX) 입력 재설정 (F1: RX는 Input) */
  { GPIO_InitTypeDef rx = {0}; rx.Pin = GPIO_PIN_3; rx.Mode = GPIO_MODE_INPUT; rx.Pull = GPIO_PULLUP; HAL_GPIO_Init(GPIOA, &rx); }

  /* USART2 수신 인터럽트 */
  __HAL_UART_ENABLE_IT(&huart2, UART_IT_RXNE);
  HAL_NVIC_SetPriority(USART2_IRQn, 1, 0);
  HAL_NVIC_EnableIRQ(USART2_IRQn);

  /* ADC(Scan+DMA) + us타이머 */
  HAL_ADCEx_Calibration_Start(&hadc1);
  HAL_ADC_Start_DMA(&hadc1, (uint32_t *)g_adc, ADC_CH_COUNT);
  HAL_TIM_Base_Start(&htim2);
  HAL_GPIO_WritePin(HC_TRIG_GPIO_Port, HC_TRIG_Pin, GPIO_PIN_RESET);


  /* 서보: 부팅 시 안전상태(닫힘)로 한 번 → detach(평상시 무신호) */
  Servo_Detach();
  Servo_Close_Valve();

  /* I2C CLCD + 엔코더 설정 타이머 초기화 */
  LCD_Init();
  Encoder_Init();
  LCD_Gotoxy(0,0); LCD_Puts("SMART GAS COCK  ");
  LCD_Gotoxy(0,1); LCD_Puts("booting...      ");

  printf("\r\n=== SMART GAS COCK : FSM + TELEMETRY ===\r\n");
  printf("btn: IDLE=open / OPEN=close / WARN,ALERT=confirm\r\n");
  printf("[flame] fire-watch only, mount AWAY from burner\r\n");
  if (HAL_I2C_IsDeviceReady(&hi2c1, MLX90614_ADDR, 3, 100) == HAL_OK) printf("[MLX90614] OK\r\n");
  else printf("[MLX90614] NOT FOUND\r\n");

  uint32_t last_print = 0;

  for (int i = 0; i < 400; i++) {          /* 약 500Hz, 0.4초 삑 */
      HAL_GPIO_TogglePin(BUZZER_PORT, BUZZER_PIN);
      HAL_Delay(1);
  }
  HAL_GPIO_WritePin(BUZZER_PORT, BUZZER_PIN, ACT_OFF);
  /* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */

    while (1)

    {

    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
        /* --- 버튼(PB9, 눌림=LOW) 폴링: 상태별 동작 --- */
        {
            static uint8_t  btn_prev = 1;
            static uint32_t btn_last = 0;
            uint8_t btn_now = (uint8_t)HAL_GPIO_ReadPin(BUTTON_GPIO_Port, BUTTON_Pin);
            if (btn_prev == 1 && btn_now == 0 && (HAL_GetTick() - btn_last) > 200) {
                btn_last = HAL_GetTick();
                switch (g_tele.state) {
                    case S_IDLE:               g_open_request  = 1; break;  /* 열기 */
                    case S_OPEN:               g_close_request = 1; break;  /* 정상 닫기 */
                    case S_WARN: case S_ALERT: g_confirm       = 1; break;  /* 확인/해제 */
                    default: break;
                }
            }
            btn_prev = btn_now;
        }

        /* --- 엔코더 회전(설정) + 푸시(확정) 폴링 --- */
        Encoder_Poll();
        EncBtn_Poll();

        /* --- CALIB 버튼(거리 보정) 폴링: 눌림 에지 → 요청 플래그 --- */
        {
            static uint8_t cb_prev = 0; static uint32_t cb_last = 0;
            uint8_t craw = (uint8_t)HAL_GPIO_ReadPin(CALIB_BTN_PORT, CALIB_BTN_PIN);
            uint8_t cpressed = CALIB_BTN_ACTIVE_LOW ? (craw==0) : (craw==1);
            if (cb_prev==0 && cpressed && (HAL_GetTick()-cb_last) > 300) { cb_last = HAL_GetTick(); g_calib_request = 1; }
            cb_prev = cpressed;
        }

        /* --- 경보 중 부저(패시브) 지속 --- */
        if (g_tele.state == S_ALERT) Buzzer_Beep(200);

        /* --- 센서 읽기 + FSM (주기적) --- */
        if ((HAL_GetTick() - last_print) >= PRINT_PERIOD_MS) {
            last_print = HAL_GetTick();

            uint16_t mq4_raw   = g_adc[MQ4_IDX];
            uint16_t flame_raw = g_adc[FLAME_IDX];
            uint8_t  flame_do  = (uint8_t)HAL_GPIO_ReadPin(FLAME_DO_GPIO_Port, FLAME_DO_Pin);

            float ambient_temp = 0.0f, object_temp = 0.0f;
            HAL_StatusTypeDef amb_st = MLX90614_ReadTemp(MLX90614_REG_AMBIENT, &ambient_temp);
            HAL_StatusTypeDef obj_st = MLX90614_ReadTemp(MLX90614_REG_OBJECT,  &object_temp);
            uint8_t temp_ok = (amb_st == HAL_OK && obj_st == HAL_OK);

            float distance_cm = 0.0f;
            HAL_StatusTypeDef hc_st = HC_SR04_ReadDistance(&distance_cm);
            uint8_t dist_ok = (hc_st == HAL_OK);

            FSM_Step(mq4_raw, flame_do, flame_raw, object_temp, ambient_temp, temp_ok, distance_cm, dist_ok);
            Tele_Print();
            LCD_UpdateStatus();
        }
  /* USER CODE END 3 */
}
}

/**
  * @brief System Clock Configuration
  * @retval None
  */
void SystemClock_Config(void)
{
  RCC_OscInitTypeDef RCC_OscInitStruct = {0};
  RCC_ClkInitTypeDef RCC_ClkInitStruct = {0};
  RCC_PeriphCLKInitTypeDef PeriphClkInit = {0};

  /** Initializes the RCC Oscillators according to the specified parameters
  * in the RCC_OscInitTypeDef structure.
  */
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSI;
  RCC_OscInitStruct.HSIState = RCC_HSI_ON;
  RCC_OscInitStruct.HSICalibrationValue = RCC_HSICALIBRATION_DEFAULT;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource = RCC_PLLSOURCE_HSI_DIV2;
  RCC_OscInitStruct.PLL.PLLMUL = RCC_PLL_MUL16;
  if (HAL_RCC_OscConfig(&RCC_OscInitStruct) != HAL_OK)
  {
    Error_Handler();
  }

  /** Initializes the CPU, AHB and APB buses clocks
  */
  RCC_ClkInitStruct.ClockType = RCC_CLOCKTYPE_HCLK|RCC_CLOCKTYPE_SYSCLK
                              |RCC_CLOCKTYPE_PCLK1|RCC_CLOCKTYPE_PCLK2;
  RCC_ClkInitStruct.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  RCC_ClkInitStruct.AHBCLKDivider = RCC_SYSCLK_DIV1;
  RCC_ClkInitStruct.APB1CLKDivider = RCC_HCLK_DIV2;
  RCC_ClkInitStruct.APB2CLKDivider = RCC_HCLK_DIV1;

  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct, FLASH_LATENCY_2) != HAL_OK)
  {
    Error_Handler();
  }
  PeriphClkInit.PeriphClockSelection = RCC_PERIPHCLK_ADC;
  PeriphClkInit.AdcClockSelection = RCC_ADCPCLK2_DIV8;
  if (HAL_RCCEx_PeriphCLKConfig(&PeriphClkInit) != HAL_OK)
  {
    Error_Handler();
  }
}

/**
  * @brief ADC1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_ADC1_Init(void)
{

  /* USER CODE BEGIN ADC1_Init 0 */

  /* USER CODE END ADC1_Init 0 */

  ADC_ChannelConfTypeDef sConfig = {0};

  /* USER CODE BEGIN ADC1_Init 1 */

  /* USER CODE END ADC1_Init 1 */

  /** Common config
  */
  hadc1.Instance = ADC1;
  hadc1.Init.ScanConvMode = ADC_SCAN_ENABLE;
  hadc1.Init.ContinuousConvMode = ENABLE;
  hadc1.Init.DiscontinuousConvMode = DISABLE;
  hadc1.Init.ExternalTrigConv = ADC_SOFTWARE_START;
  hadc1.Init.DataAlign = ADC_DATAALIGN_RIGHT;
  hadc1.Init.NbrOfConversion = 2;
  if (HAL_ADC_Init(&hadc1) != HAL_OK)
  {
    Error_Handler();
  }

  /** Configure Regular Channel
  */
  sConfig.Channel = ADC_CHANNEL_0;
  sConfig.Rank = ADC_REGULAR_RANK_1;
  sConfig.SamplingTime = ADC_SAMPLETIME_55CYCLES_5;
  if (HAL_ADC_ConfigChannel(&hadc1, &sConfig) != HAL_OK)
  {
    Error_Handler();
  }

  /** Configure Regular Channel
  */
  sConfig.Channel = ADC_CHANNEL_1;
  sConfig.Rank = ADC_REGULAR_RANK_2;
  if (HAL_ADC_ConfigChannel(&hadc1, &sConfig) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN ADC1_Init 2 */

  /* USER CODE END ADC1_Init 2 */

}

/**
  * @brief I2C1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_I2C1_Init(void)
{

  /* USER CODE BEGIN I2C1_Init 0 */

  /* USER CODE END I2C1_Init 0 */

  /* USER CODE BEGIN I2C1_Init 1 */

  /* USER CODE END I2C1_Init 1 */
  hi2c1.Instance = I2C1;
  hi2c1.Init.ClockSpeed = 100000;
  hi2c1.Init.DutyCycle = I2C_DUTYCYCLE_2;
  hi2c1.Init.OwnAddress1 = 0;
  hi2c1.Init.AddressingMode = I2C_ADDRESSINGMODE_7BIT;
  hi2c1.Init.DualAddressMode = I2C_DUALADDRESS_DISABLE;
  hi2c1.Init.OwnAddress2 = 0;
  hi2c1.Init.GeneralCallMode = I2C_GENERALCALL_DISABLE;
  hi2c1.Init.NoStretchMode = I2C_NOSTRETCH_DISABLE;
  if (HAL_I2C_Init(&hi2c1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN I2C1_Init 2 */

  /* USER CODE END I2C1_Init 2 */

}

/**
  * @brief I2C2 Initialization Function
  * @param None
  * @retval None
  */
static void MX_I2C2_Init(void)
{

  /* USER CODE BEGIN I2C2_Init 0 */

  /* USER CODE END I2C2_Init 0 */

  /* USER CODE BEGIN I2C2_Init 1 */

  /* USER CODE END I2C2_Init 1 */
  hi2c2.Instance = I2C2;
  hi2c2.Init.ClockSpeed = 100000;
  hi2c2.Init.DutyCycle = I2C_DUTYCYCLE_2;
  hi2c2.Init.OwnAddress1 = 0;
  hi2c2.Init.AddressingMode = I2C_ADDRESSINGMODE_7BIT;
  hi2c2.Init.DualAddressMode = I2C_DUALADDRESS_DISABLE;
  hi2c2.Init.OwnAddress2 = 0;
  hi2c2.Init.GeneralCallMode = I2C_GENERALCALL_DISABLE;
  hi2c2.Init.NoStretchMode = I2C_NOSTRETCH_DISABLE;
  if (HAL_I2C_Init(&hi2c2) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN I2C2_Init 2 */

  /* USER CODE END I2C2_Init 2 */

}

/**
  * @brief TIM1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_TIM1_Init(void)
{

  /* USER CODE BEGIN TIM1_Init 0 */

  /* USER CODE END TIM1_Init 0 */

  TIM_Encoder_InitTypeDef sConfig = {0};
  TIM_MasterConfigTypeDef sMasterConfig = {0};

  /* USER CODE BEGIN TIM1_Init 1 */

  /* USER CODE END TIM1_Init 1 */
  htim1.Instance = TIM1;
  htim1.Init.Prescaler = 0;
  htim1.Init.CounterMode = TIM_COUNTERMODE_UP;
  htim1.Init.Period = 65535;
  htim1.Init.ClockDivision = TIM_CLOCKDIVISION_DIV1;
  htim1.Init.RepetitionCounter = 0;
  htim1.Init.AutoReloadPreload = TIM_AUTORELOAD_PRELOAD_DISABLE;
  sConfig.EncoderMode = TIM_ENCODERMODE_TI12;
  sConfig.IC1Polarity = TIM_ICPOLARITY_RISING;
  sConfig.IC1Selection = TIM_ICSELECTION_DIRECTTI;
  sConfig.IC1Prescaler = TIM_ICPSC_DIV1;
  sConfig.IC1Filter = 0;
  sConfig.IC2Polarity = TIM_ICPOLARITY_RISING;
  sConfig.IC2Selection = TIM_ICSELECTION_DIRECTTI;
  sConfig.IC2Prescaler = TIM_ICPSC_DIV1;
  sConfig.IC2Filter = 0;
  if (HAL_TIM_Encoder_Init(&htim1, &sConfig) != HAL_OK)
  {
    Error_Handler();
  }
  sMasterConfig.MasterOutputTrigger = TIM_TRGO_RESET;
  sMasterConfig.MasterSlaveMode = TIM_MASTERSLAVEMODE_DISABLE;
  if (HAL_TIMEx_MasterConfigSynchronization(&htim1, &sMasterConfig) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN TIM1_Init 2 */

  /* USER CODE END TIM1_Init 2 */

}

/**
  * @brief TIM2 Initialization Function
  * @param None
  * @retval None
  */
static void MX_TIM2_Init(void)
{

  /* USER CODE BEGIN TIM2_Init 0 */

  /* USER CODE END TIM2_Init 0 */

  TIM_ClockConfigTypeDef sClockSourceConfig = {0};
  TIM_MasterConfigTypeDef sMasterConfig = {0};

  /* USER CODE BEGIN TIM2_Init 1 */

  /* USER CODE END TIM2_Init 1 */
  htim2.Instance = TIM2;
  htim2.Init.Prescaler = 63;
  htim2.Init.CounterMode = TIM_COUNTERMODE_UP;
  htim2.Init.Period = 65535;
  htim2.Init.ClockDivision = TIM_CLOCKDIVISION_DIV1;
  htim2.Init.AutoReloadPreload = TIM_AUTORELOAD_PRELOAD_DISABLE;
  if (HAL_TIM_Base_Init(&htim2) != HAL_OK)
  {
    Error_Handler();
  }
  sClockSourceConfig.ClockSource = TIM_CLOCKSOURCE_INTERNAL;
  if (HAL_TIM_ConfigClockSource(&htim2, &sClockSourceConfig) != HAL_OK)
  {
    Error_Handler();
  }
  sMasterConfig.MasterOutputTrigger = TIM_TRGO_RESET;
  sMasterConfig.MasterSlaveMode = TIM_MASTERSLAVEMODE_DISABLE;
  if (HAL_TIMEx_MasterConfigSynchronization(&htim2, &sMasterConfig) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN TIM2_Init 2 */

  /* USER CODE END TIM2_Init 2 */

}

/**
  * @brief TIM3 Initialization Function
  * @param None
  * @retval None
  */
static void MX_TIM3_Init(void)
{

  /* USER CODE BEGIN TIM3_Init 0 */

  /* USER CODE END TIM3_Init 0 */

  TIM_ClockConfigTypeDef sClockSourceConfig = {0};
  TIM_MasterConfigTypeDef sMasterConfig = {0};
  TIM_OC_InitTypeDef sConfigOC = {0};

  /* USER CODE BEGIN TIM3_Init 1 */

  /* USER CODE END TIM3_Init 1 */
  htim3.Instance = TIM3;
  htim3.Init.Prescaler = 63;
  htim3.Init.CounterMode = TIM_COUNTERMODE_UP;
  htim3.Init.Period = 19999;
  htim3.Init.ClockDivision = TIM_CLOCKDIVISION_DIV1;
  htim3.Init.AutoReloadPreload = TIM_AUTORELOAD_PRELOAD_DISABLE;
  if (HAL_TIM_Base_Init(&htim3) != HAL_OK)
  {
    Error_Handler();
  }
  sClockSourceConfig.ClockSource = TIM_CLOCKSOURCE_INTERNAL;
  if (HAL_TIM_ConfigClockSource(&htim3, &sClockSourceConfig) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_TIM_PWM_Init(&htim3) != HAL_OK)
  {
    Error_Handler();
  }
  sMasterConfig.MasterOutputTrigger = TIM_TRGO_RESET;
  sMasterConfig.MasterSlaveMode = TIM_MASTERSLAVEMODE_DISABLE;
  if (HAL_TIMEx_MasterConfigSynchronization(&htim3, &sMasterConfig) != HAL_OK)
  {
    Error_Handler();
  }
  sConfigOC.OCMode = TIM_OCMODE_PWM1;
  sConfigOC.Pulse = 1500;
  sConfigOC.OCPolarity = TIM_OCPOLARITY_HIGH;
  sConfigOC.OCFastMode = TIM_OCFAST_DISABLE;
  if (HAL_TIM_PWM_ConfigChannel(&htim3, &sConfigOC, TIM_CHANNEL_1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN TIM3_Init 2 */

  /* USER CODE END TIM3_Init 2 */
  HAL_TIM_MspPostInit(&htim3);

}

/**
  * @brief USART2 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART2_UART_Init(void)
{

  /* USER CODE BEGIN USART2_Init 0 */

  /* USER CODE END USART2_Init 0 */

  /* USER CODE BEGIN USART2_Init 1 */

  /* USER CODE END USART2_Init 1 */
  huart2.Instance = USART2;
  huart2.Init.BaudRate = 115200;
  huart2.Init.WordLength = UART_WORDLENGTH_8B;
  huart2.Init.StopBits = UART_STOPBITS_1;
  huart2.Init.Parity = UART_PARITY_NONE;
  huart2.Init.Mode = UART_MODE_TX_RX;
  huart2.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart2.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart2) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART2_Init 2 */

  /* USER CODE END USART2_Init 2 */

}

/**
  * Enable DMA controller clock
  */
static void MX_DMA_Init(void)
{

  /* DMA controller clock enable */
  __HAL_RCC_DMA1_CLK_ENABLE();

  /* DMA interrupt init */
  /* DMA1_Channel1_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Channel1_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA1_Channel1_IRQn);

}

/**
  * @brief GPIO Initialization Function
  * @param None
  * @retval None
  */
static void MX_GPIO_Init(void)
{
  GPIO_InitTypeDef GPIO_InitStruct = {0};
  /* USER CODE BEGIN MX_GPIO_Init_1 */

  /* USER CODE END MX_GPIO_Init_1 */

  /* GPIO Ports Clock Enable */
  __HAL_RCC_GPIOC_CLK_ENABLE();
  __HAL_RCC_GPIOD_CLK_ENABLE();
  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOB_CLK_ENABLE();

  /*Configure GPIO pin Output Level */
  HAL_GPIO_WritePin(GPIOC, LED_RED_Pin|LED_YELLOW_Pin, GPIO_PIN_RESET);

  /*Configure GPIO pin Output Level */
  HAL_GPIO_WritePin(GPIOA, LED_GREEN_Pin|LD2_Pin, GPIO_PIN_RESET);

  /*Configure GPIO pin Output Level */
  HAL_GPIO_WritePin(GPIOB, HC_TRIG_Pin|BUZZER_Pin, GPIO_PIN_RESET);

  /*Configure GPIO pin : B1_Pin */
  GPIO_InitStruct.Pin = B1_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_IT_RISING;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  HAL_GPIO_Init(B1_GPIO_Port, &GPIO_InitStruct);

  /*Configure GPIO pins : LED_RED_Pin LED_YELLOW_Pin */
  GPIO_InitStruct.Pin = LED_RED_Pin|LED_YELLOW_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &GPIO_InitStruct);

  /*Configure GPIO pins : FLAME_DO_Pin MQ4_DO_Pin HC_ECHO_Pin */
  GPIO_InitStruct.Pin = FLAME_DO_Pin|MQ4_DO_Pin|HC_ECHO_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_INPUT;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  HAL_GPIO_Init(GPIOC, &GPIO_InitStruct);

  /*Configure GPIO pins : LED_GREEN_Pin LD2_Pin */
  GPIO_InitStruct.Pin = LED_GREEN_Pin|LD2_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);

  /*Configure GPIO pin : CALIB_BTN_Pin */
  GPIO_InitStruct.Pin = CALIB_BTN_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_INPUT;
  GPIO_InitStruct.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(CALIB_BTN_GPIO_Port, &GPIO_InitStruct);

  /*Configure GPIO pins : HC_TRIG_Pin BUZZER_Pin */
  GPIO_InitStruct.Pin = HC_TRIG_Pin|BUZZER_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOB, &GPIO_InitStruct);

  /*Configure GPIO pin : ENCODER_Pin */
  GPIO_InitStruct.Pin = ENCODER_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_INPUT;
  GPIO_InitStruct.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(ENCODER_GPIO_Port, &GPIO_InitStruct);

  /*Configure GPIO pin : BUTTON_Pin */
  GPIO_InitStruct.Pin = BUTTON_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_IT_FALLING;
  GPIO_InitStruct.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(BUTTON_GPIO_Port, &GPIO_InitStruct);

  /* EXTI interrupt init*/
  HAL_NVIC_SetPriority(EXTI9_5_IRQn, 1, 0);
  HAL_NVIC_EnableIRQ(EXTI9_5_IRQn);

  HAL_NVIC_SetPriority(EXTI15_10_IRQn, 1, 0);
  HAL_NVIC_EnableIRQ(EXTI15_10_IRQn);

  /* USER CODE BEGIN MX_GPIO_Init_2 */

  /* USER CODE END MX_GPIO_Init_2 */
}

/* USER CODE BEGIN 4 */
/* USART2 수신 인터럽트 (CubeMX가 안 만들었으므로 직접 정의) */
void USART2_IRQHandler(void)
{
    uint32_t sr = huart2.Instance->SR;
    if (sr & USART_SR_RXNE) { uint8_t c = (uint8_t)(huart2.Instance->DR & 0xFF); g_rx_count++; Servo_HandleChar(c); }
    else if (sr & USART_SR_ORE) { (void)huart2.Instance->DR; }
}

/* USER CODE END 4 */

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */

    __disable_irq();



    while (1)

    {

    }

  /* USER CODE END Error_Handler_Debug */
}
#ifdef USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* USER CODE BEGIN 6 */

  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */
