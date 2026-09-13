// =============================================================================
// main_pcam.c — PCAM 5C 카메라 + BNN 가속기 통합 테스트
//
// Phase 1: 카메라 초기화 + 프레임 캡처 + 픽셀 덤프 (카메라 동작 확인)
// Phase 2: 그레이스케일 변환 + 256×256 리사이즈 + PL 추론
// =============================================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xaxidma.h"
#include "xiicps.h"
#include "xgpiops.h"
#include "sleep.h"
#include "weights_hls.h"
#include "ff.h"          // FatFs — SD 카드 검증 모드용

// =============================================================================
// [1] 주소 정의
// =============================================================================
#define ACCEL_BASE        0x40000000
#define DMA_BASE          0x40400000
#define CAM_GPIO_PIN      54  // PS EMIO GPIO pin 54 = cam_gpio[0]
#define IIC_SCLK_RATE     100000  // 100kHz I2C
#define VDMA_BASE         0x43000000
#define DPHY_BASE         0x43C00000  // Digilent MIPI_D_PHY_RX

// Accelerator 레지스터
#define REG_CTRL          0x00
#define REG_STATUS        0x04
#define REG_BRAM_ADDR     0x08
#define REG_BRAM_DATA     0x0C
#define REG_BRAM_SEL      0x10

// VDMA 레지스터 (S2MM = Write channel)
#define VDMA_S2MM_CR      0x30    // Control
#define VDMA_S2MM_SR      0x34    // Status
#define VDMA_S2MM_IRQ     0x3C    // IRQ mask
#define VDMA_S2MM_ADDR    0xAC    // Start address
#define VDMA_S2MM_HSIZE   0xA4    // Horizontal size (bytes)
#define VDMA_S2MM_STRIDE  0xA8    // Stride (bytes)
#define VDMA_S2MM_VSIZE   0xA0    // Vertical size (lines) — 쓰면 전송 시작

// OV5640 I2C
#define OV5640_ADDR       0x3C    // 7-bit I2C address
#define CAM_WIDTH         1280
#define CAM_HEIGHT        720
// CSI-2 Rx 출력: 40-bit TDATA (4 pixels × 10-bit packed)
// VDMA HSIZE = 1280 * 10 / 8 = 1600 bytes (packed RAW10)
#define CAM_HSIZE_BYTES   1600    // 수평 라인 바이트 수
#define CAM_BPP           2       // PS에서 메모리 접근용 (실제 packed는 1.25)

// 프레임 버퍼 (DDR 상위 영역, PS heap과 겹치지 않도록)
#define FRAME_BUF_0       0x10000000
#define FRAME_BUF_1       0x10200000
#define FRAME_BUF_2       0x10400000
#define FRAME_SIZE        (CAM_HSIZE_BYTES * CAM_HEIGHT)  // 1600 * 720 = 1,152,000

// 추론 관련 (기존과 동일)
#define SZ_L1_W           1568
#define SZ_B1             3072
#define SZ_S1             (SZ_L1_W + SZ_B1)
#define SZ_BIN            12096
#define SZ_SC             20480
#define SZ_PARA           2240
#define SZ_HEAD           257
#define TOTAL_SZ          (SZ_S1 + SZ_BIN + SZ_SC + SZ_PARA + SZ_HEAD)
#define SZ_BCONV2         2304
#define SZ_BCONV3         9216
#define SZ_SC2            4096
#define PARA_OFF_WEFF2    0
#define PARA_OFF_BEFF2    128
#define PARA_OFF_WEFF3    256
#define PARA_OFF_BEFF3    512
#define IMG_PIXELS        (256*256)
#define IMG_PACKED_WORDS   (IMG_PIXELS / 4)
#define FINAL_OUT_WORDS   256
#define PROB_THRESH       0.8f
#define COUNTS_PER_MS     333333ULL

// =============================================================================
// [2] 전역 변수
// =============================================================================
static XAxiDma  AxiDma;
static XIicPs   Iic;
static XGpioPs  Gpio;

static uint32_t ALL_WEIGHTS[TOTAL_SZ]              __attribute__((aligned(64)));
static uint32_t IMG_PACKED[IMG_PACKED_WORDS]        __attribute__((aligned(64)));
static int32_t  PL_RESULT_LOGITS[FINAL_OUT_WORDS]  __attribute__((aligned(64)));
static unsigned char img_gray[256 * 256];           // 그레이스케일 256×256
static unsigned char lbl_raw[256];                  // SD 검증용 라벨
#define SAMPLES 600                                 // SD 테스트 이미지 수

// =============================================================================
// [3] 유틸리티
// =============================================================================
static unsigned long long get_time(void) {
    unsigned int l, h, h2;
    do { h = Xil_In32(0xF8F00204); l = Xil_In32(0xF8F00200); h2 = Xil_In32(0xF8F00204); } while (h != h2);
    return (((unsigned long long)h) << 32) | l;
}

static inline int mult_q16(int a, int b) { return (int)(((long long)a * b + 32768LL) >> 16); }

// =============================================================================
// [4] OV5640 I2C 드라이버 (PS EMIO I2C — XIicPs)
// =============================================================================
static int ov5640_write_reg(u16 reg_addr, u8 data) {
    u8 buf[3];
    buf[0] = (reg_addr >> 8) & 0xFF;
    buf[1] = reg_addr & 0xFF;
    buf[2] = data;
    return XIicPs_MasterSendPolled(&Iic, buf, 3, OV5640_ADDR);
}

static u8 ov5640_read_reg(u16 reg_addr) {
    u8 buf[2], val = 0;
    buf[0] = (reg_addr >> 8) & 0xFF;
    buf[1] = reg_addr & 0xFF;
    XIicPs_MasterSendPolled(&Iic, buf, 2, OV5640_ADDR);
    while (XIicPs_BusIsBusy(&Iic));
    XIicPs_MasterRecvPolled(&Iic, &val, 1, OV5640_ADDR);
    while (XIicPs_BusIsBusy(&Iic));
    return val;
}

// OV5640 레지스터 테이블 (16-bit addr, 8-bit data)
typedef struct { u16 addr; u8 val; } ov5640_reg_t;

// ============================================================================
// Digilent 레퍼런스 cfg_init_[] — 완전한 기본 초기화 (OV5640.h에서 추출)
// ============================================================================
static const ov5640_reg_t ov5640_cfg_init[] = {
    {0x3008, 0x42}, // Software power down
    {0x3103, 0x03}, // System clock from PLL
    {0x3017, 0x00}, {0x3018, 0x00},
    {0x3034, 0x18}, // MIPI 8-bit (init 기본값, 모드에서 변경)
    // PLL1: 레퍼런스=12MHz(pre=1), 우리=24MHz → pre=2로 변경
    // VCO = 24/2 × 56 = 672MHz, MIPI_CLK = 672/2 = 336MHz (동일)
    {0x3035, 0x11}, {0x3036, 0x38}, {0x3037, 0x12}, {0x3108, 0x01},
    // PLL2
    {0x303D, 0x10}, {0x303B, 0x19},
    // Analog/system
    {0x3630, 0x2e}, {0x3631, 0x0e}, {0x3632, 0xe2}, {0x3633, 0x23},
    {0x3621, 0xe0}, {0x3704, 0xa0}, {0x3703, 0x5a}, {0x3715, 0x78},
    {0x3717, 0x01}, {0x370b, 0x60}, {0x3705, 0x1a}, {0x3905, 0x02},
    {0x3906, 0x10}, {0x3901, 0x0a}, {0x3731, 0x02},
    {0x3600, 0x37}, {0x3601, 0x33}, {0x302d, 0x60},
    {0x3620, 0x52}, {0x371b, 0x20}, {0x471c, 0x50},
    // AEC
    {0x3a13, 0x43}, {0x3a18, 0x00}, {0x3a19, 0xf8},
    {0x3635, 0x13}, {0x3636, 0x06}, {0x3634, 0x44}, {0x3622, 0x01},
    {0x3c01, 0x34}, {0x3c04, 0x28}, {0x3c05, 0x98},
    {0x3c06, 0x00}, {0x3c07, 0x08}, {0x3c08, 0x00}, {0x3c09, 0x1c},
    {0x3c0a, 0x9c}, {0x3c0b, 0x40},
    // Test pattern off
    {0x503d, 0x00},
    // ISP vflip
    {0x3820, 0x46},
    // MIPI 2-lane enable
    {0x300e, 0x45},
    // MIPI bus LP11 when no packet
    {0x4800, 0x14},
    {0x302e, 0x08},
    // Output format: RGB565 (init 기본값)
    {0x4300, 0x6f}, {0x501f, 0x01},
    // Misc
    {0x4713, 0x03}, {0x4407, 0x04}, {0x440e, 0x00},
    {0x460b, 0x35}, {0x460c, 0x20}, {0x3824, 0x01},
    // ISP: LENC, RAW gamma, BPC, WPC, Color interp
    {0x5000, 0x07},
    // AWB + Color matrix
    {0x5001, 0x03},
    {0x0000, 0x00} // 종료
};

// ============================================================================
// Digilent 레퍼런스 cfg_720p_60fps_[] — 1280x720 RAW10 MIPI
// ============================================================================
static const ov5640_reg_t ov5640_cfg_720p[] = {
    // PLL: MIPISCLK=280M, SCLK=56M, PCLK=56M
    // 레퍼런스=12MHz(pre=1.5), 우리=24MHz → pre=3으로 변경
    // VCO = 24/3 × 70 = 560MHz, MIPISCLK = 560/2 = 280MHz (동일)
    {0x3035, 0x21}, {0x3036, 0x46}, {0x3037, 0x03}, {0x3108, 0x11},
    // RAW10 MIPI
    {0x3034, 0x1A},
    // Window: 0,8 ~ 2619,1947
    {0x3800, 0x00}, {0x3801, 0x00}, {0x3802, 0x00}, {0x3803, 0x08},
    {0x3804, 0x0A}, {0x3805, 0x3B}, {0x3806, 0x07}, {0x3807, 0x9B},
    // Offset
    {0x3810, 0x00}, {0x3811, 0x00}, {0x3812, 0x00}, {0x3813, 0x00},
    // Output: 1280x720
    {0x3808, 0x05}, {0x3809, 0x00}, {0x380a, 0x02}, {0x380b, 0xD0},
    // HTS/VTS
    {0x380c, 0x07}, {0x380d, 0x68}, {0x380e, 0x03}, {0x380f, 0xD8},
    // Subsample 3x3
    {0x3814, 0x31}, {0x3815, 0x31},
    // Horizontal binning
    {0x3821, 0x01},
    // MIPI timing
    {0x4837, 36},
    // Anti-green
    {0x3618, 0x00}, {0x3612, 0x59}, {0x3708, 0x64}, {0x3709, 0x52}, {0x370c, 0x03},
    // RAW output
    {0x4300, 0x00}, {0x501f, 0x03},
    {0x0000, 0x00} // 종료
};

static int ov5640_init(void) {
    printf("[CAM] OV5640 초기화 시작...\n\r");

    // Chip ID 확인
    u8 id_h = ov5640_read_reg(0x300A);
    u8 id_l = ov5640_read_reg(0x300B);
    printf("[CAM] Chip ID = 0x%02X%02X", id_h, id_l);
    if (id_h == 0x56 && id_l == 0x40) {
        printf(" (OV5640 확인)\n\r");
    } else {
        printf(" (알 수 없는 칩!)\n\r");
        return -1;
    }

    // Step 1: Software Reset
    ov5640_write_reg(0x3103, 0x11);
    ov5640_write_reg(0x3008, 0x82);
    usleep(1000000); // 1초 대기 (레퍼런스 동일)

    // Step 2: Base Init (cfg_init_[])
    printf("[CAM] Base init 적용 중...\n\r");
    for (int i = 0; ov5640_cfg_init[i].addr != 0x0000; i++) {
        ov5640_write_reg(ov5640_cfg_init[i].addr, ov5640_cfg_init[i].val);
    }

    // Step 3: Mode Config — 720p RAW10 MIPI
    // 먼저 software power down
    ov5640_write_reg(0x3008, 0x42);
    printf("[CAM] 720p RAW10 모드 적용 중...\n\r");
    for (int i = 0; ov5640_cfg_720p[i].addr != 0x0000; i++) {
        ov5640_write_reg(ov5640_cfg_720p[i].addr, ov5640_cfg_720p[i].val);
    }

    // Step 4: Streaming ON
    ov5640_write_reg(0x3008, 0x02);
    usleep(300000); // 300ms 안정화 (PLL lock 대기)

    // ── 레지스터 검증: PLL/MIPI 설정 readback ──
    printf("[검증] PLL/MIPI 레지스터 readback:\n\r");
    printf("  0x3008=0x%02X (기대:0x02=streaming)\n\r", ov5640_read_reg(0x3008));
    printf("  0x3034=0x%02X (기대:0x1A=RAW10)\n\r",     ov5640_read_reg(0x3034));
    printf("  0x3035=0x%02X (기대:0x21)\n\r",             ov5640_read_reg(0x3035));
    printf("  0x3036=0x%02X (기대:0x46=mult70)\n\r",      ov5640_read_reg(0x3036));
    printf("  0x3037=0x%02X (기대:0x03=pre3)\n\r",        ov5640_read_reg(0x3037));
    printf("  0x3108=0x%02X (기대:0x11)\n\r",             ov5640_read_reg(0x3108));
    printf("  0x300E=0x%02X (기대:0x45=2lane MIPI)\n\r",  ov5640_read_reg(0x300E));
    printf("  0x4800=0x%02X (기대:0x14=LP11)\n\r",        ov5640_read_reg(0x4800));
    printf("  0x4300=0x%02X (기대:0x00=RAW)\n\r",         ov5640_read_reg(0x4300));
    printf("  0x501F=0x%02X (기대:0x03=ISP RAW)\n\r",     ov5640_read_reg(0x501F));
    printf("  0x3820=0x%02X (vflip)\n\r",                  ov5640_read_reg(0x3820));
    printf("  0x3821=0x%02X (mirror/binning)\n\r",         ov5640_read_reg(0x3821));
    printf("  0x3103=0x%02X (기대:0x03=PLL clk)\n\r",     ov5640_read_reg(0x3103));

    // MIPI 상태 레지스터 (undocumented but sometimes useful)
    printf("  0x4750=0x%02X (MIPI status)\n\r",            ov5640_read_reg(0x4750));
    printf("  0x4751=0x%02X (MIPI status)\n\r",            ov5640_read_reg(0x4751));

    // SC (System Control) 상태
    printf("  0x302C=0x%02X (IO pad)\n\r",                 ov5640_read_reg(0x302C));
    printf("  0x302E=0x%02X (IO ctrl)\n\r",                ov5640_read_reg(0x302E));

    printf("[CAM] OV5640 초기화 완료 (1280×720 RAW10 MIPI 2-lane)\n\r");
    return 0;
}

// =============================================================================
// [5] VDMA 드라이버
// =============================================================================
static void vdma_init(void) {
    // S2MM (write) 채널 리셋
    Xil_Out32(VDMA_BASE + VDMA_S2MM_CR, 0x04); // Reset
    while (Xil_In32(VDMA_BASE + VDMA_S2MM_CR) & 0x04); // 리셋 완료 대기

    // 프레임 버퍼 주소 설정
    Xil_Out32(VDMA_BASE + VDMA_S2MM_ADDR, FRAME_BUF_0);

    // 프레임 크기 설정 — packed RAW10: 4 pixels = 5 bytes
    Xil_Out32(VDMA_BASE + VDMA_S2MM_HSIZE, CAM_HSIZE_BYTES);   // 1600 bytes/line
    Xil_Out32(VDMA_BASE + VDMA_S2MM_STRIDE, CAM_HSIZE_BYTES);  // stride = hsize

    // S2MM 시작: Run + Circular mode
    Xil_Out32(VDMA_BASE + VDMA_S2MM_CR, 0x01);

    // VSIZE 쓰기 → 전송 시작 트리거
    Xil_Out32(VDMA_BASE + VDMA_S2MM_VSIZE, CAM_HEIGHT);

    printf("[VDMA] 프레임 캡처 시작 (%dx%d, HSIZE=%d, buf=0x%08X)\n\r",
           CAM_WIDTH, CAM_HEIGHT, CAM_HSIZE_BYTES, FRAME_BUF_0);
}

static void vdma_stop(void) {
    // S2MM 정지: Run 비트 클리어
    u32 cr = Xil_In32(VDMA_BASE + VDMA_S2MM_CR);
    Xil_Out32(VDMA_BASE + VDMA_S2MM_CR, cr & ~0x01);
    // 정지 확인 (Halted 비트 대기)
    int timeout = 10000;
    while (!(Xil_In32(VDMA_BASE + VDMA_S2MM_SR) & 0x01) && --timeout > 0);
}

static void vdma_start(void) {
    // S2MM 재시작
    Xil_Out32(VDMA_BASE + VDMA_S2MM_ADDR, FRAME_BUF_0);
    Xil_Out32(VDMA_BASE + VDMA_S2MM_HSIZE, CAM_HSIZE_BYTES);
    Xil_Out32(VDMA_BASE + VDMA_S2MM_STRIDE, CAM_HSIZE_BYTES);
    Xil_Out32(VDMA_BASE + VDMA_S2MM_CR, 0x01);
    Xil_Out32(VDMA_BASE + VDMA_S2MM_VSIZE, CAM_HEIGHT);
}

static int vdma_wait_frame(void) {
    // S2MM 상태 폴링: Frame Count 변화 확인
    int timeout = 1000000;
    u32 sr;
    do {
        sr = Xil_In32(VDMA_BASE + VDMA_S2MM_SR);
        if (sr & 0x01) break; // Frame complete (Halted 아닌지 확인)
        if (sr & 0x4000) break; // Error
    } while (--timeout > 0);

    if (timeout <= 0 || (sr & 0x4000)) {
        printf("[VDMA] 프레임 캡처 타임아웃/에러 (SR=0x%08X)\n\r", (unsigned)sr);
        return -1;
    }

    // 캐시 무효화 (DMA가 DDR에 직접 쓰므로)
    Xil_DCacheInvalidateRange(FRAME_BUF_0, FRAME_SIZE);
    return 0;
}

// =============================================================================
// [6] 이미지 변환: Unpacked 4×10-bit RAW10 → Grayscale 256×256
// =============================================================================
// CSI-2 Rx 출력: TDATA[39:0] = {P3[9:0], P2[9:0], P1[9:0], P0[9:0]}
// DDR 메모리 (little-endian):
//   Byte0 = P0[7:0],  Byte1 = {P1[5:0],P0[9:8]}
//   Byte2 = {P2[3:0],P1[9:6]},  Byte3 = {P3[1:0],P2[9:4]}
//   Byte4 = P3[9:2]
// 각 픽셀의 상위 8비트(10-bit >> 2) 추출:
static inline uint8_t raw10_pixel(const uint8_t *src, int row, int col) {
    int group = col / 4;
    int pix   = col % 4;
    int base  = row * CAM_HSIZE_BYTES + group * 5;
    uint8_t b0 = src[base], b1 = src[base+1], b2 = src[base+2];
    uint8_t b3 = src[base+3], b4 = src[base+4];

    switch (pix) {
        case 0: return ((b1 & 0x03) << 6) | (b0 >> 2);   // P0[9:2]
        case 1: return ((b2 & 0x0F) << 4) | (b1 >> 4);   // P1[9:2]
        case 2: return ((b3 & 0x3F) << 2) | (b2 >> 6);   // P2[9:2]
        case 3: return b4;                                  // P3[9:2]
        default: return 0;
    }
}

// Gamma LUT: RAW 센서의 linear 데이터 → 사람 눈에 자연스러운 밝기
// gamma ≈ 0.45 (sRGB 표준), BNN 학습 이미지와 유사한 밝기 분포
static uint8_t gamma_lut[256];
static int gamma_initialized = 0;

static void init_gamma_lut(void) {
    for (int i = 0; i < 256; i++) {
        float normalized = (float)i / 255.0f;
        float corrected = powf(normalized, 0.45f); // gamma = 1/2.2
        int val = (int)(corrected * 255.0f + 0.5f);
        gamma_lut[i] = (uint8_t)(val > 255 ? 255 : val);
    }
    gamma_initialized = 1;
}

static void convert_frame_to_gray256(void) {
    uint8_t *src = (uint8_t *)FRAME_BUF_0;

    // 1280×720 → 256×256 축소
    // Bayer RGGB 2×2 블록 정렬 평균: (R + Gr + Gb + B) / 4
    for (int r = 0; r < 256; r++) {
        int src_r = (r * CAM_HEIGHT / 256) & ~1;

        for (int c = 0; c < 256; c++) {
            int src_c = (c * CAM_WIDTH / 256) & ~1;

            unsigned int sum = raw10_pixel(src, src_r,     src_c)
                             + raw10_pixel(src, src_r,     src_c + 1)
                             + raw10_pixel(src, src_r + 1, src_c)
                             + raw10_pixel(src, src_r + 1, src_c + 1);

            uint8_t gray = (uint8_t)(sum / 4);

            // Gamma 보정: 0=OFF, 1=ON (0.45 sRGB)
            #define USE_GAMMA 0   // 감마 끔(리니어). 옛 PNG가 gamma=0이라 동일하게 유지
            #if USE_GAMMA
            if (!gamma_initialized) init_gamma_lut();
            gray = gamma_lut[gray];
            #endif

            img_gray[r * 256 + c] = gray;
        }
    }
}

// =============================================================================
// [7] 가중치 로드 (기존과 동일)
// =============================================================================
static void pack_weights(uint32_t* dest, const void* src, int num_oc, int words_per_oc) {
    const uint32_t* src32 = (const uint32_t*)src;
    int idx = 0;
    for (int oc_group = 0; oc_group < num_oc; oc_group += 2)
        for (int w = 0; w < words_per_oc; w++) {
            dest[idx++] = src32[(oc_group + 0) * words_per_oc + w];
            dest[idx++] = src32[(oc_group + 1) * words_per_oc + w];
        }
}

static void pack_sc_int16(uint32_t* dest, const int* src, int num_oc, int vals_per_oc) {
    int idx = 0;
    for (int oc_group = 0; oc_group < num_oc; oc_group += 2)
        for (int w = 0; w < vals_per_oc; w++) {
            int16_t c0 = (int16_t)src[(oc_group + 0) * vals_per_oc + w];
            int16_t c1 = (int16_t)src[(oc_group + 1) * vals_per_oc + w];
            dest[idx++] = ((uint32_t)(uint16_t)c1 << 16) | ((uint32_t)(uint16_t)c0);
        }
}

static uint32_t bconv3_reordered[256 * 36];
static void reorder_b3_weights(void) {
    for (int oc = 0; oc < 256; oc++) {
        const uint32_t* src = &bconv3_w[oc * 36];
        uint32_t* dst = &bconv3_reordered[oc * 36];
        for (int pos = 0; pos < 9; pos++) {
            dst[pos * 2 + 0] = src[pos * 4 + 0];
            dst[pos * 2 + 1] = src[pos * 4 + 1];
        }
        for (int pos = 0; pos < 9; pos++) {
            dst[18 + pos * 2 + 0] = src[pos * 4 + 2];
            dst[18 + pos * 2 + 1] = src[pos * 4 + 3];
        }
    }
}

static void precompute_folded_params(void) {
    int para_base = SZ_S1 + SZ_BIN + SZ_SC;
    for (int oc = 0; oc < 128; oc++) {
        int32_t av = mult_q16(bnn2_alpha[oc], bn3_v_inv[oc]);
        int32_t weff = mult_q16(av, bn3_w[oc]);
        int32_t mv = mult_q16(bn3_m[oc], bn3_v_inv[oc]);
        int32_t beff = bn3_b[oc] - mult_q16(mv, bn3_w[oc]);
        ALL_WEIGHTS[para_base + PARA_OFF_WEFF2 + oc] = (uint32_t)weff;
        ALL_WEIGHTS[para_base + PARA_OFF_BEFF2 + oc] = (uint32_t)beff;
    }
    for (int oc = 0; oc < 256; oc++) {
        int32_t av = mult_q16(bnn3_alpha[oc], bn4_v_inv[oc]);
        int32_t weff = mult_q16(av, bn4_w[oc]);
        int32_t mv = mult_q16(bn4_m[oc], bn4_v_inv[oc]);
        int32_t beff = bn4_b[oc] - mult_q16(mv, bn4_w[oc]);
        ALL_WEIGHTS[para_base + PARA_OFF_WEFF3 + oc] = (uint32_t)weff;
        ALL_WEIGHTS[para_base + PARA_OFF_BEFF3 + oc] = (uint32_t)beff;
    }
}

static void load_weights(void) {
    memset(ALL_WEIGHTS, 0, sizeof(ALL_WEIGHTS));
    for (int ch = 0; ch < 32; ch++)
        for (int k = 0; k < 49; k++)
            ALL_WEIGHTS[ch * 49 + k] = (uint32_t)conv1_w[ch * 49 + k];

    int off = SZ_L1_W;
    for (int i = 0; i < 32; i++) ALL_WEIGHTS[off + 0  + i] = (uint32_t)bn1_w[i];
    for (int i = 0; i < 32; i++) ALL_WEIGHTS[off + 32 + i] = (uint32_t)bn1_b[i];
    for (int i = 0; i < 32; i++) ALL_WEIGHTS[off + 64 + i] = (uint32_t)bn1_m[i];
    for (int i = 0; i < 32; i++) ALL_WEIGHTS[off + 96 + i] = (uint32_t)bn1_v_inv[i];
    for (int oc = 0; oc < 64; oc++)
        for (int p = 0; p < 9; p++)
            ALL_WEIGHTS[off + 128 + oc * 9 + p] = (uint32_t)bconv1_w[oc * 9 + p];
    for (int i = 0; i < 64; i++) ALL_WEIGHTS[off + 704 + i] = (uint32_t)bnn1_alpha[i];
    for (int i = 0; i < 64; i++) ALL_WEIGHTS[off + 768  + i] = (uint32_t)bn2_w[i];
    for (int i = 0; i < 64; i++) ALL_WEIGHTS[off + 832  + i] = (uint32_t)bn2_b[i];
    for (int i = 0; i < 64; i++) ALL_WEIGHTS[off + 896  + i] = (uint32_t)bn2_m[i];
    for (int i = 0; i < 64; i++) ALL_WEIGHTS[off + 960  + i] = (uint32_t)bn2_v_inv[i];
    for (int oc = 0; oc < 64; oc++)
        for (int ich = 0; ich < 32; ich++)
            ALL_WEIGHTS[off + 1024 + oc * 32 + ich] = (uint32_t)shortcut1_w[oc * 32 + ich];

    pack_weights(&ALL_WEIGHTS[SZ_S1], bconv2_w, 128, 18);
    reorder_b3_weights();
    pack_weights(&ALL_WEIGHTS[SZ_S1 + SZ_BCONV2], bconv3_reordered, 256, 36);
    pack_sc_int16(&ALL_WEIGHTS[SZ_S1 + SZ_BIN], shortcut2_w, 128, 64);
    pack_sc_int16(&ALL_WEIGHTS[SZ_S1 + SZ_BIN + SZ_SC2], shortcut3_w, 256, 128);
    precompute_folded_params();

    int head_base = SZ_S1 + SZ_BIN + SZ_SC + SZ_PARA;
    for (int i = 0; i < 256; i++) ALL_WEIGHTS[head_base + i] = head_w[i];
    ALL_WEIGHTS[head_base + 256] = (uint32_t)(int32_t)head_b;
}

// =============================================================================
// [8] 이미지 패킹 + PL 추론 (기존과 동일)
// =============================================================================
static void pack_image(void) {
    // ARM little-endian: img_gray를 직접 uint32_t*로 캐스팅 가능
    // 하지만 안전하게 명시적 패킹
    for (int i = 0; i < IMG_PACKED_WORDS; i++) {
        int base = i * 4;
        IMG_PACKED[i] = ((uint32_t)img_gray[base + 3] << 24) |
                        ((uint32_t)img_gray[base + 2] << 16) |
                        ((uint32_t)img_gray[base + 1] <<  8) |
                        ((uint32_t)img_gray[base + 0]);
    }
}

static int run_pl_inference(void) {
    int Status;

    Xil_DCacheFlushRange((UINTPTR)PL_RESULT_LOGITS, sizeof(PL_RESULT_LOGITS));
    Status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)PL_RESULT_LOGITS,
                                    sizeof(PL_RESULT_LOGITS), XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) return -1;

    pack_image();
    Xil_DCacheFlushRange((UINTPTR)IMG_PACKED, sizeof(IMG_PACKED));

    Xil_Out32(ACCEL_BASE + REG_CTRL, 0x00000001); // Stage 1 모드

    Status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)IMG_PACKED,
                                    sizeof(IMG_PACKED), XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) return -1;

    while (XAxiDma_Busy(&AxiDma, XAXIDMA_DMA_TO_DEVICE));

    int timeout = 100000000;
    while (!((Xil_In32(ACCEL_BASE + REG_STATUS) >> 1) & 1) && --timeout > 0);
    if (timeout <= 0) { printf("[FATAL] Stage 1 타임아웃\n\r"); return -1; }

    Xil_Out32(ACCEL_BASE + REG_CTRL, 0x80000001); // Stage 2 시작

    timeout = 100000000;
    while (XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA) && --timeout > 0);
    if (timeout <= 0) { printf("[FATAL] Stage 2 타임아웃\n\r"); return -1; }

    Xil_DCacheInvalidateRange((UINTPTR)PL_RESULT_LOGITS, sizeof(PL_RESULT_LOGITS));
    Xil_Out32(ACCEL_BASE + REG_CTRL, 0x00000000);

    timeout = 1000000;
    while (!((Xil_In32(ACCEL_BASE + REG_STATUS) >> 1) & 1) && --timeout > 0);

    return 0;
}

// =============================================================================
// [9] 메인
// =============================================================================
int main(void) {
    init_platform();
    printf("\n\r==============================================\n\r");
    printf("  PCAM 5C + BNN 가속기 통합 테스트\n\r");
    printf("==============================================\n\r");

    // ══════════════════════════════════════════════
    // 초기화 (1회만 실행 — 이후 while(1)로 반복)
    // ══════════════════════════════════════════════

    // ── PS GPIO 초기화 ──
    XGpioPs_Config *GpioCfg = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_BASEADDR);
    if (!GpioCfg) { printf("[ERROR] GPIO config\n\r"); return -1; }
    XGpioPs_CfgInitialize(&Gpio, GpioCfg, GpioCfg->BaseAddr);
    XGpioPs_SetDirectionPin(&Gpio, CAM_GPIO_PIN, 1);
    XGpioPs_SetOutputEnablePin(&Gpio, CAM_GPIO_PIN, 1);

    // ── 카메라 Power Cycle ──
    XGpioPs_WritePin(&Gpio, CAM_GPIO_PIN, 0);
    usleep(500000);
    XGpioPs_WritePin(&Gpio, CAM_GPIO_PIN, 1);
    usleep(500000);
    printf("[1/5] 카메라 Power Cycle\n\r");

    // ── DMA 초기화 ──
    XAxiDma_Config *CfgPtr = XAxiDma_LookupConfig(DMA_BASE);
    if (!CfgPtr || XAxiDma_CfgInitialize(&AxiDma, CfgPtr) != XST_SUCCESS || XAxiDma_HasSg(&AxiDma)) {
        printf("[ERROR] DMA 초기화 실패\n\r"); return -1;
    }
    printf("[2/5] DMA 초기화\n\r");

    // ── PS I2C 초기화 ──
    XIicPs_Config *IicCfg = XIicPs_LookupConfig(XPAR_XIICPS_0_BASEADDR);
    if (!IicCfg) { printf("[ERROR] PS I2C config 없음\n\r"); return -1; }
    XIicPs_CfgInitialize(&Iic, IicCfg, IicCfg->BaseAddress);
    XIicPs_SetSClk(&Iic, IIC_SCLK_RATE);
    printf("[3/5] I2C 초기화\n\r");

    // ── D-PHY 활성화 ──
    Xil_Out32(DPHY_BASE + 0x00, 0x02);
    usleep(100000);
    printf("[4/5] D-PHY 활성화 (CR=0x%08X)\n\r", Xil_In32(DPHY_BASE + 0x00));

    // Chip ID 읽기
    u8 id_h = ov5640_read_reg(0x300A);
    u8 id_l = ov5640_read_reg(0x300B);
    printf("[Chip ID] 0x%02X%02X\n\r", id_h, id_l);

    // ── OV5640 초기화 + 스트리밍 시작 ──
    if (ov5640_init() != 0) {
        printf("[ERROR] OV5640 초기화 실패\n\r");
        return -1;
    }
    printf("[5/5] OV5640 스트리밍 시작 (0x3008=0x%02X)\n\r", ov5640_read_reg(0x3008));
    usleep(500000);

    // ── VDMA 시작 ──
    vdma_init();
    printf("\n\r[시스템 준비 완료]\n\r");

    // ── Phase 1: 프레임 캡처 테스트 ──
    printf("\n\r--- Phase 1: 프레임 캡처 테스트 ---\n\r");

    // ⭐ 프레임 버퍼를 0으로 초기화 → VDMA가 실제 쓰는지 확인
    memset((void*)FRAME_BUF_0, 0, FRAME_SIZE);
    Xil_DCacheFlushRange(FRAME_BUF_0, FRAME_SIZE);
    printf("[진단] 프레임 버퍼 0 초기화 완료\n\r");

    usleep(1000000); // 1초 — 충분한 대기

    // 상태 레지스터 덤프
    printf("[진단] D-PHY CR = 0x%08X\n\r", Xil_In32(DPHY_BASE + 0x00));
    printf("[진단] D-PHY SR = 0x%08X\n\r", Xil_In32(DPHY_BASE + 0x04));
    for (int r = 0; r <= 0x20; r += 4)
        printf("  DPHY[0x%02X]=0x%08X\n\r", r, Xil_In32(DPHY_BASE + r));
    printf("[진단] VDMA S2MM CR   = 0x%08X\n\r", Xil_In32(VDMA_BASE + VDMA_S2MM_CR));
    printf("[진단] VDMA S2MM SR   = 0x%08X\n\r", Xil_In32(VDMA_BASE + VDMA_S2MM_SR));

    Xil_DCacheInvalidateRange(FRAME_BUF_0, FRAME_SIZE);

    // 프레임 버퍼 픽셀 덤프
    uint8_t *frame = (uint8_t *)FRAME_BUF_0;
    int nonzero = 0;
    for (int i = 0; i < FRAME_SIZE; i++)
        if (frame[i] != 0) nonzero++;

    printf("[프레임] 전체 %d 바이트 중 non-zero: %d (%.1f%%)\n\r",
           FRAME_SIZE, nonzero, nonzero * 100.0f / FRAME_SIZE);

    // 포맷 진단: Packed RAW10 덤프 (5바이트=4픽셀)
    printf("[RAW 바이트] 첫 2행 × 20바이트 (4 groups of 5):\n\r");
    for (int r = 0; r < 2; r++) {
        printf("  row%d: ", r);
        for (int b = 0; b < 20; b++) {
            printf("%02X ", frame[r * CAM_HSIZE_BYTES + b]);
            if ((b % 5) == 4) printf("| ");
        }
        printf("\n\r");
    }

    // 4×10-bit unpacked → 8-bit 변환 후 픽셀 값
    printf("[Pixel 8bit] 상단 16×2:\n\r");
    for (int r = 0; r < 2; r++) {
        printf("  row%d: ", r);
        for (int c = 0; c < 16; c++)
            printf("%3d ", raw10_pixel(frame, r, c));
        printf("\n\r");
    }

    // 프레임 변화 확인: 첫 4바이트를 저장, Phase 2에서 비교용
    printf("[프레임 ID] 첫 4바이트: %02X %02X %02X %02X\n\r",
           frame[0], frame[1], frame[2], frame[3]);

    if (nonzero == 0) {
        printf("[경고] 프레임이 전부 0 — 카메라/MIPI/VDMA 연결 확인 필요\n\r");
        printf("  → D-PHY SR = 0x%08X\n\r", Xil_In32(DPHY_BASE + 0x04));
        printf("  → VDMA S2MM SR  = 0x%08X\n\r", Xil_In32(VDMA_BASE + VDMA_S2MM_SR));
        return -1;
    }

    // ── 그레이스케일 이미지를 DDR 고정 주소에 저장 ──
    // XSCT에서 바로 바이너리 덤프 가능
    #define IMG_DUMP_ADDR  0x10800000  // DDR 내 이미지 저장 주소
    Xil_DCacheInvalidateRange(FRAME_BUF_0, FRAME_SIZE);
    convert_frame_to_gray256();
    memcpy((void*)IMG_DUMP_ADDR, img_gray, 256 * 256);
    Xil_DCacheFlushRange(IMG_DUMP_ADDR, 256 * 256);
    printf("[OK] 그레이스케일 256x256 → DDR 0x%08X 저장 완료\n\r", IMG_DUMP_ADDR);

    // 그레이스케일 이미지 통계 — 밝기 분포 진단
    {
        int pmin = 255, pmax = 0;
        unsigned long psum = 0;
        int hist[4] = {0}; // 0-63, 64-127, 128-191, 192-255
        for (int i = 0; i < 256*256; i++) {
            uint8_t v = img_gray[i];
            if (v < pmin) pmin = v;
            if (v > pmax) pmax = v;
            psum += v;
            hist[v >> 6]++;
        }
        printf("[이미지 통계] min=%d max=%d avg=%d\n\r", pmin, pmax, (int)(psum / (256*256)));
        printf("[밝기 분포] 0-63:%d  64-127:%d  128-191:%d  192-255:%d\n\r",
               hist[0], hist[1], hist[2], hist[3]);
    }

    // ── Phase 2: 그레이스케일 변환 + 추론 ──
    printf("\n\r--- Phase 2: 추론 테스트 ---\n\r");

    // 가중치 로드
    load_weights();
    Xil_Out32(ACCEL_BASE + REG_CTRL, 0x00000000);
    Xil_DCacheFlushRange((UINTPTR)ALL_WEIGHTS, sizeof(ALL_WEIGHTS));
    if (XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)ALL_WEIGHTS, sizeof(ALL_WEIGHTS), XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS) {
        printf("[ERROR] 가중치 DMA 실패\n\r"); return -1;
    }
    while (XAxiDma_Busy(&AxiDma, XAXIDMA_DMA_TO_DEVICE));

    uint32_t sr = Xil_In32(ACCEL_BASE + REG_STATUS);
    if (!((sr >> 2) & 1)) printf("[WARN] load_done=0\n\r");
    else printf("[OK] 가중치 로드 완료\n\r");

    // ══════════════════════════════════════════════
    // 모드 선택 루프
    // ══════════════════════════════════════════════
    #define NUM_FRAMES 30
    int batch = 0;

    while (1) {
    printf("\n\r==============================================\n\r");
    printf("  모드 선택:\n\r");
    printf("  1: SD 카드 검증 (BNN_DATA 600장, 정확도 측정)\n\r");
    printf("  2: 카메라 실시간 추론 (%d프레임)\n\r", NUM_FRAMES);
    printf("  3: 학습 데이터 수집 (연속 캡처 → DDR)\n\r");  // [ADDED]
    printf("==============================================\n\r");
    printf(">>> 번호 입력 (1 또는 2): ");

    char mode_ch = '2';
    mode_ch = inbyte(); // UART에서 1바이트 읽기
    printf("%c\n\r", mode_ch);

    // ────────────────────────────────────────────
    // 모드 1: SD 카드 검증
    // ────────────────────────────────────────────
    if (mode_ch == '1') {
        printf("\n\r--- SD 카드 검증 모드 (%d 이미지) ---\n\r", SAMPLES);
        vdma_stop(); // 카메라 VDMA 정지 — DMA 경합 방지

        static FATFS fs;
        if (f_mount(&fs, "0:/", 1) != FR_OK) {
            printf("[ERROR] SD 마운트 실패\n\r");
            vdma_start();
            continue;
        }
        printf("[OK] SD 카드 마운트\n\r");

        int total_match = 0, pl_timeout_cnt = 0;
        printf("\n\rID\tProb\tPred\t\tGTC\tHit\tPL_ms\tRes\tAcc\n\r");
        printf("----------------------------------------------------------------------\n\r");

        // 분석용 배열
        static float all_max_prob[600];
        static float all_mean_prob[600];
        static int   all_gtc[600];
        static int   all_hit3x3[600];
        static int   all_cells[600];
        memset(all_max_prob, 0, sizeof(all_max_prob));
        memset(all_mean_prob, 0, sizeof(all_mean_prob));
        memset(all_gtc, 0, sizeof(all_gtc));
        memset(all_hit3x3, 0, sizeof(all_hit3x3));
        memset(all_cells, 0, sizeof(all_cells));

        for (int i = 0; i < SAMPLES; i++) {
            char fni[32], fnl[32];
            sprintf(fni, "BNN_DATA/i%d.bin", i);
            sprintf(fnl, "BNN_DATA/l%d.bin", i);
            FIL fi, fl; UINT br;
            if (f_open(&fi, fni, FA_READ) != FR_OK ||
                f_open(&fl, fnl, FA_READ) != FR_OK) {
                printf("[ERROR] 파일 열기 실패: %s\n\r", fni); break;
            }
            f_read(&fi, img_gray, 65536, &br);
            f_read(&fl, lbl_raw,  256,   &br);
            f_close(&fi); f_close(&fl);

            // 첫 이미지의 픽셀 통계 (카메라 비교용)
            if (i == 0) {
                int smin=255, smax=0; unsigned long ssum=0;
                int shist[4]={0};
                for (int p=0; p<65536; p++) {
                    uint8_t v=img_gray[p];
                    if(v<smin)smin=v; if(v>smax)smax=v; ssum+=v; shist[v>>6]++;
                }
                printf("[SD 이미지 #0 통계] min=%d max=%d avg=%d\n\r", smin, smax, (int)(ssum/65536));
                printf("[SD 밝기 분포] 0-63:%d 64-127:%d 128-191:%d 192-255:%d\n\r",
                       shist[0], shist[1], shist[2], shist[3]);
            }

            unsigned long long t0 = get_time();
            if (run_pl_inference() != 0) {
                printf("[TIMEOUT] 이미지 %d\n\r", i);
                pl_timeout_cnt++;
                Xil_Out32(ACCEL_BASE + REG_CTRL, 0x00000000);
                continue;
            }
            unsigned long long t1 = get_time();

            float max_p = 0.0f, p_sum = 0.0f;
            int px = 0, py = 0, hit_cnt = 0, gtc = 0, cells = 0;
            for (int g = 0; g < 256; g++) {
                float logit = (float)PL_RESULT_LOGITS[g] / 65536.0f;
                float prob = 1.0f / (1.0f + expf(-logit));
                p_sum += prob;
                if (lbl_raw[g]) { gtc++; if (prob > PROB_THRESH) hit_cnt++; }
                if (prob > max_p) { max_p = prob; px = g % 16; py = g / 16; }
                if (prob > PROB_THRESH) cells++;
            }
            float mean_p = p_sum / 256.0f;

            int hit_3x3 = 0;
            if (gtc > 0) {
                for (int dy = -1; dy <= 1; dy++)
                    for (int dx = -1; dx <= 1; dx++) {
                        int ny = py+dy, nx = px+dx;
                        if (ny>=0 && ny<16 && nx>=0 && nx<16 && lbl_raw[ny*16+nx]) hit_3x3 = 1;
                    }
            }

            // 분석용 저장
            all_max_prob[i] = max_p;
            all_mean_prob[i] = mean_p;
            all_gtc[i] = gtc;
            all_hit3x3[i] = hit_3x3;
            all_cells[i] = cells;

            int is_match = (gtc > 0) ? (hit_3x3 && max_p > PROB_THRESH) : (max_p <= PROB_THRESH);
            if (is_match) total_match++;
            int pl_ms = (int)((t1 - t0) / COUNTS_PER_MS);
            int acc_x100 = (total_match * 10000) / (i + 1);

            printf("%d\t%d%%\tmean=%d%%\tcells=%d\t(%2d,%2d)\tGTC=%d\t%d\t%s\t%d.%02d%%\n\r",
                   i, (int)(max_p*100), (int)(mean_p*100), cells,
                   px, py, gtc, pl_ms,
                   is_match ? "PASS" : "FAIL", acc_x100/100, acc_x100%100);
        }

        printf("\n\r======================================\n\r");
        printf("  최종 정확도: %d/%d = %.2f%% (임계값 %d%%)\n\r",
               total_match, SAMPLES, (float)total_match / SAMPLES * 100.0f,
               (int)(PROB_THRESH * 100));
        printf("  PL 타임아웃: %d건\n\r", pl_timeout_cnt);

        // ── 다양한 임계값별 정확도 ──
        printf("\n\r  [임계값별 정확도]\n\r");
        float thresholds[] = {0.50f, 0.60f, 0.70f, 0.75f, 0.80f, 0.85f, 0.90f, 0.95f};
        for (int t = 0; t < 8; t++) {
            int match_t = 0;
            for (int i = 0; i < SAMPLES; i++) {
                if (all_max_prob[i] < 0) continue; // 타임아웃
                int has_person = (all_gtc[i] > 0);
                int detected = (all_max_prob[i] > thresholds[t]);
                int hit = all_hit3x3[i];
                int ok = has_person ? (hit && detected) : (!detected);
                if (ok) match_t++;
            }
            printf("    Thresh=%2d%%  →  %d/%d = %.2f%%\n\r",
                   (int)(thresholds[t]*100), match_t, SAMPLES,
                   (float)match_t / SAMPLES * 100.0f);
        }

        // ── cells 기반 정확도 ──
        printf("\n\r  [cells >= N 기반 정확도] (임계값 80%%에서의 셀 수)\n\r");
        // 사람/배경 cells 통계
        {
            int p_cnt = 0, b_cnt = 0;
            float p_cells_sum = 0, b_cells_sum = 0;
            int p_cells_min = 999, p_cells_max = 0;
            int b_cells_min = 999, b_cells_max = 0;
            for (int i = 0; i < SAMPLES; i++) {
                if (all_max_prob[i] <= 0) continue;
                if (all_gtc[i] > 0) {
                    p_cnt++; p_cells_sum += all_cells[i];
                    if (all_cells[i] < p_cells_min) p_cells_min = all_cells[i];
                    if (all_cells[i] > p_cells_max) p_cells_max = all_cells[i];
                } else {
                    b_cnt++; b_cells_sum += all_cells[i];
                    if (all_cells[i] < b_cells_min) b_cells_min = all_cells[i];
                    if (all_cells[i] > b_cells_max) b_cells_max = all_cells[i];
                }
            }
            printf("    사람(%d장): cells 평균=%.1f min=%d max=%d\n\r",
                   p_cnt, p_cells_sum/p_cnt, p_cells_min, p_cells_max);
            printf("    배경(%d장): cells 평균=%.1f min=%d max=%d\n\r",
                   b_cnt, b_cells_sum/b_cnt, b_cells_min, b_cells_max);
        }

        for (int n = 1; n <= 10; n++) {
            int match_c = 0;
            for (int i = 0; i < SAMPLES; i++) {
                if (all_max_prob[i] <= 0) continue;
                int has_person = (all_gtc[i] > 0);
                int detected = (all_cells[i] >= n);
                int ok = has_person ? detected : (!detected);
                if (ok) match_c++;
            }
            printf("    cells>=%2d  →  %d/%d = %.2f%%\n\r",
                   n, match_c, SAMPLES, (float)match_c / SAMPLES * 100.0f);
        }
        printf("======================================\n\r");

        f_mount(NULL, "0:/", 0); // SD 언마운트
        vdma_start(); // VDMA 재시작
        continue;
    }

    // ────────────────────────────────────────────
    // 모드 3: 학습 데이터 수집 (연속 캡처 → DDR)  [ADDED]
    // 캡처 후 XSCT에서 dump_captures.tcl 실행하여 PC로 덤프
    // ────────────────────────────────────────────
    if (mode_ch == '3') {
        #define CAP_BASE        0x10800000u   // IMG_DUMP_ADDR과 동일 시작 주소
        #define CAP_SIZE        (256 * 256)   // 65536 bytes per frame
        #define CAP_NUM         100           // 캡처 장수 (100장 = 6.4MB)
        #define CAP_INTERVAL_US 500000        // 캡처 간격 0.5초

        printf("\n\r--- 학습 데이터 수집: %d장, %dms 간격 ---\n\r",
               CAP_NUM, CAP_INTERVAL_US / 1000);
        printf("캡처 동안 사람 위치/배경 구도를 천천히 바꿔주세요.\n\r");

        for (int n = 0; n < CAP_NUM; n++) {
            usleep(CAP_INTERVAL_US);
            Xil_DCacheInvalidateRange(FRAME_BUF_0, FRAME_SIZE);
            vdma_stop();                      // AXI 경합 방지 (모드 2와 동일 패턴)
            convert_frame_to_gray256();
            vdma_start();
            memcpy((void*)(CAP_BASE + (unsigned)n * CAP_SIZE), img_gray, CAP_SIZE);
            Xil_DCacheFlushRange(CAP_BASE + (unsigned)n * CAP_SIZE, CAP_SIZE);
            if ((n + 1) % 10 == 0)
                printf("  [%d/%d] 저장 완료 (마지막 주소 0x%08X)\n\r",
                       n + 1, CAP_NUM, CAP_BASE + (unsigned)n * CAP_SIZE);
        }
        printf("[완료] DDR 0x%08X ~ 0x%08X 에 %d장 저장\n\r",
               CAP_BASE, CAP_BASE + CAP_NUM * CAP_SIZE - 1, CAP_NUM);
        printf(">>> XSCT: source dump_captures.tcl\n\r");
        continue;
    }

    // ────────────────────────────────────────────
    // 모드 2: 카메라 실시간 추론
    // ────────────────────────────────────────────
    batch++;
    printf("\n\r################ 카메라 배치 #%d ################\n\r", batch);

    // 통계 초기화
    int   stat_ok = 0, stat_fail = 0;
    int   stat_detect = 0;
    float stat_prob_sum = 0.0f;
    float stat_prob_min = 1.0f, stat_prob_max = 0.0f;
    int   stat_time_sum = 0, stat_time_min = 99999, stat_time_max = 0;
    int   stat_grid[256]; memset(stat_grid, 0, sizeof(stat_grid));
    int   stat_above50 = 0, stat_above70 = 0, stat_above90 = 0;

    // 프레임 캡처 + 변환 + 추론 루프
    for (int frame_id = 0; frame_id < NUM_FRAMES; frame_id++) {
        // ① 새 프레임 캡처 대기
        usleep(100000); // 100ms
        Xil_DCacheInvalidateRange(FRAME_BUF_0, FRAME_SIZE);

        // ② VDMA 정지 — AXI 버스 독점 방지
        vdma_stop();

        // 프레임 변화 확인 (처음 3프레임만)
        if (frame_id < 3)
            printf("  [buf] %02X %02X %02X %02X\n\r",
                   ((uint8_t*)FRAME_BUF_0)[0], ((uint8_t*)FRAME_BUF_0)[1],
                   ((uint8_t*)FRAME_BUF_0)[2], ((uint8_t*)FRAME_BUF_0)[3]);

        // 그레이스케일 256×256 변환
        convert_frame_to_gray256();

        // ③ 추론
        unsigned long long t0 = get_time();
        if (run_pl_inference() != 0) {
            printf("[TIMEOUT] 프레임 %d 추론 실패\n\r", frame_id);
            Xil_Out32(ACCEL_BASE + REG_CTRL, 0x00000000);
            stat_fail++;
            vdma_start();
            continue;
        }
        unsigned long long t1 = get_time();
        int pl_ms = (int)((t1 - t0) / COUNTS_PER_MS);

        // ④ VDMA 재시작
        vdma_start();

        // 결과 분석 — 절대 확률 + 상대 확률 (max - mean)
        float max_p = 0.0f, prob_sum = 0.0f;
        int px = 0, py = 0;
        int cells_above_thresh = 0;
        for (int g = 0; g < 256; g++) {
            float logit = (float)PL_RESULT_LOGITS[g] / 65536.0f;
            float prob = 1.0f / (1.0f + expf(-logit));
            prob_sum += prob;
            if (prob > max_p) { max_p = prob; px = g % 16; py = g / 16; }
            if (prob > PROB_THRESH) cells_above_thresh++;
        }
        float mean_p = prob_sum / 256.0f;

        // 판정: cells >= 3 AND max > 75%
        int judge_person = (cells_above_thresh >= 5) && (max_p > 0.75f);

        // 통계 누적
        stat_ok++;
        stat_prob_sum += max_p;
        if (max_p < stat_prob_min) stat_prob_min = max_p;
        if (max_p > stat_prob_max) stat_prob_max = max_p;
        stat_time_sum += pl_ms;
        if (pl_ms < stat_time_min) stat_time_min = pl_ms;
        if (pl_ms > stat_time_max) stat_time_max = pl_ms;
        if (judge_person) { stat_detect++; stat_grid[py * 16 + px]++; }
        if (max_p > 0.50f) stat_above50++;
        if (max_p > 0.70f) stat_above70++;
        if (max_p > 0.90f) stat_above90++;
        printf("[Frame %2d] max=%2d%% mean=%2d%% cells=%2d → %s | pos=(%2d,%2d) %dms\n\r",
               frame_id, (int)(max_p*100), (int)(mean_p*100), cells_above_thresh,
               judge_person ? "★사람" : "  배경",
               px, py, pl_ms);
    }

    // ══════════════════════════════════════════════
    // 통계 요약
    // ══════════════════════════════════════════════
    printf("\n\r==============================================\n\r");
    printf("  추론 결과 통계 (%d 프레임)\n\r", NUM_FRAMES);
    printf("==============================================\n\r");

    printf("[성공률] %d/%d 성공, %d 실패\n\r", stat_ok, NUM_FRAMES, stat_fail);

    if (stat_ok > 0) {
        printf("[검출률] %d/%d (%.1f%%) — cells>=3 AND max>75%%\n\r",
               stat_detect, stat_ok, stat_detect * 100.0f / stat_ok);
        printf("[확률분포] >50%%:%d  >70%%:%d  >90%%:%d\n\r",
               stat_above50, stat_above70, stat_above90);
        printf("[확률] 평균=%d%%  최소=%d%%  최대=%d%%\n\r",
               (int)(stat_prob_sum / stat_ok * 100),
               (int)(stat_prob_min * 100),
               (int)(stat_prob_max * 100));
        printf("[속도] 평균=%dms  최소=%dms  최대=%dms  (%.1f FPS)\n\r",
               stat_time_sum / stat_ok, stat_time_min, stat_time_max,
               1000.0f / (stat_time_sum / stat_ok));

        // 검출 위치 히트맵 (가장 자주 검출된 상위 3개 셀)
        printf("[검출 위치] 상위 빈도:\n\r");
        for (int top = 0; top < 3; top++) {
            int best_g = -1, best_cnt = 0;
            for (int g = 0; g < 256; g++) {
                if (stat_grid[g] > best_cnt) { best_cnt = stat_grid[g]; best_g = g; }
            }
            if (best_g < 0 || best_cnt == 0) break;
            printf("  #%d: pos=(%d,%d) — %d회 (%d%%)\n\r",
                   top + 1, best_g % 16, best_g / 16, best_cnt,
                   best_cnt * 100 / stat_detect);
            stat_grid[best_g] = 0; // 다음 반복에서 제외
        }
    }

    printf("==============================================\n\r");

    // DDR에 최신 그레이스케일 저장 (XSCT 덤프용)
    Xil_DCacheInvalidateRange(FRAME_BUF_0, FRAME_SIZE);
    convert_frame_to_gray256();
    memcpy((void*)IMG_DUMP_ADDR, img_gray, 256 * 256);
    Xil_DCacheFlushRange(IMG_DUMP_ADDR, 256 * 256);

    // 모드 선택 메뉴로 돌아감

    } // end while(1)

    return 0;
}