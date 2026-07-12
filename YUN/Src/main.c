/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  ******************************************************************************
  * @attention
  *
  * <h2><center>&copy; Copyright (c) 2019 STMicroelectronics.
  * All rights reserved.</center></h2>
  *
  * This software component is licensed by ST under BSD 3-Clause license,
  * the "License"; You may not use this file except in compliance with the
  * License. You may obtain a copy of the License at:
  *                        opensource.org/licenses/BSD-3-Clause
  *
  ******************************************************************************
  */
/* USER CODE END Header */

/* Includes ------------------------------------------------------------------*/
#include "main.h"
#include "adc.h"
#include "i2c.h"
#include "gpio.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "sk6812.h"
#include "i2c_ex/i2c_ex.h"
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define YUN_FW_VERSION    0x01  /* read back with command 0xFE; factory firmware NACKs it */

#define CMD_READ_LIGHT    0x00
#define CMD_SET_LED       0x01
#define CMD_SLEEP         0x02
#define CMD_READ_VERSION  0xFE

#define AWAKE_TIMEOUT_MS  500   /* auto-Stop after this much I2C inactivity */
#define BOOT_GRACE_MS     3000  /* stay awake after reset so SWD attach is easy */
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/

/* USER CODE BEGIN PV */

/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
/* USER CODE BEGIN PFP */

/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */
__IO uint32_t uiAdcValue = 0;
__IO uint32_t uiAdcValueBuf[40];
__IO uint8_t ucPt = 0;

__IO uint32_t last_activity = 0;
__IO uint8_t sleep_request = 0;
static uint32_t awake_timeout = BOOT_GRACE_MS;

extern I2C_HandleTypeDef hi2c1;
extern ADC_HandleTypeDef hadc;

/* Called on every I2C address match (weak symbol in i2c_ex.c). */
void i2c1_addr_req_callback(uint8_t TransferDirection) {
  UNUSED(TransferDirection);
  last_activity = HAL_GetTick();
}

static void enter_stop_mode(void)
{
  GPIO_InitTypeDef GPIO_InitStruct = {0};

  HAL_ADC_Stop_IT(&hadc);

  /* Errata DM00091791 (no I2C WUPEN on F030): the I2C peripheral must be
     disabled (PE=0) before Stop, else BUSY can latch and block the bus. */
  HAL_I2C_DisableListen_IT(&hi2c1);
  __HAL_I2C_DISABLE(&hi2c1);

  /* Wake on the falling SDA edge of a START condition. SDA idles high, so
     any bus traffic (ours or the SHT20/BMP280's) wakes us — harmless. */
  GPIO_InitStruct.Pin = GPIO_PIN_10;
  GPIO_InitStruct.Mode = GPIO_MODE_IT_FALLING;
  GPIO_InitStruct.Pull = GPIO_NOPULL; /* the bus has external pull-ups */
  HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);
  __HAL_GPIO_EXTI_CLEAR_IT(GPIO_PIN_10);
  HAL_NVIC_ClearPendingIRQ(EXTI4_15_IRQn);
  HAL_NVIC_EnableIRQ(EXTI4_15_IRQn);

  HAL_SuspendTick();
  HAL_PWR_EnterSTOPMode(PWR_LOWPOWERREGULATOR_ON, PWR_STOPENTRY_WFI);

  /* Awake again: clock is HSI 8 MHz — restore the 64 MHz PLL (the SK6812
     driver's NOP timing depends on it) before anything else. */
  SystemClock_Config();
  HAL_ResumeTick();

  HAL_NVIC_DisableIRQ(EXTI4_15_IRQn);
  HAL_GPIO_DeInit(GPIOA, GPIO_PIN_10); /* also clears the EXTI line config */
  GPIO_InitStruct.Pin = GPIO_PIN_10;
  GPIO_InitStruct.Mode = GPIO_MODE_AF_OD;
  GPIO_InitStruct.Pull = GPIO_PULLUP;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_HIGH;
  GPIO_InitStruct.Alternate = GPIO_AF4_I2C1;
  HAL_GPIO_Init(GPIOA, &GPIO_InitStruct);

  __HAL_I2C_ENABLE(&hi2c1);
  HAL_I2C_EnableListen_IT(&hi2c1);

  HAL_ADC_Start_IT(&hadc);

  awake_timeout = AWAKE_TIMEOUT_MS;
  sleep_request = 0;
  last_activity = HAL_GetTick();
}

void HAL_ADC_ConvCpltCallback(ADC_HandleTypeDef* hadc)
{
  uiAdcValueBuf[ucPt++] = HAL_ADC_GetValue(hadc);
  if (ucPt > 39) {
    uint32_t ave = 0;
    for (uint8_t i = 0; i < 40; i++) {
      ave += uiAdcValueBuf[i];
    }
    uiAdcValue = ave / 40;
    ucPt = 0;
  }
}

void i2c1_receive_callback(uint8_t *rx_data, uint16_t len) {
  last_activity = HAL_GetTick();
  if (rx_data[0] == CMD_SET_LED) {
    if (rx_data[1] > 13 && len == 5) {
      neopixel_set_all_color(rx_data[2] << 8 | rx_data[3] << 16 | rx_data[4]);
    }
    else {
      neopixel_set_color(rx_data[1], rx_data[2] << 8 | rx_data[3] << 16 | rx_data[4]);
    }
    neopixel_show();
  }
  else if (rx_data[0] == CMD_READ_LIGHT) {
    i2c1_set_send_data((uint8_t *)&uiAdcValue, 2);
  }
  else if (rx_data[0] == CMD_SLEEP) {
    sleep_request = 1;
  }
  else if (rx_data[0] == CMD_READ_VERSION) {
    static uint8_t fw_version = YUN_FW_VERSION;
    i2c1_set_send_data(&fw_version, 1);
  }
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
  MX_ADC_Init();
  MX_I2C1_Init();
  /* USER CODE BEGIN 2 */
  HAL_I2C_EnableListen_IT(&hi2c1);
  HAL_ADC_Start_IT(&hadc);
  sk6812_init(14); 
  neopixel_set_all_color(0x000000);
  neopixel_show();
  /* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  last_activity = HAL_GetTick();
  while (1)
  {
    if ((sleep_request || (HAL_GetTick() - last_activity) >= awake_timeout)
        && !(hi2c1.Instance->ISR & I2C_ISR_BUSY)) {
      /* The BUSY check keeps us from killing a transaction in flight; a
         START that sneaks in after it is missed once and the master retries,
         same as any transaction that arrives while asleep. */
      enter_stop_mode();
    }
    else {
      __WFI(); /* Sleep (not Stop) until the next interrupt while awake */
    }

    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
  }
  /* USER CODE END 3 */
}

/**
  * @brief System Clock Configuration
  * @retval None
  */


/* USER CODE BEGIN 4 */
void SystemClock_Config(void) {
  FLASH->ACR &= ~(0x00000017);
  //FLASH->ACR |=  (FLASH_ACR_LATENCY |
  FLASH->ACR |= (2 << FLASH_ACR_LATENCY_Pos | FLASH_ACR_PRFTBE);
  // Configure the PLL to (HSI / 2) * 16 = 64MHz.
  RCC->CFGR &= ~(RCC_CFGR_PLLMUL |
    RCC_CFGR_PLLSRC);
  RCC->CFGR |= (RCC_CFGR_PLLSRC_HSI_DIV2 | RCC_CFGR_PLLMUL16);
  // Turn the PLL on and wait for it to be ready.
  RCC->CR |= (RCC_CR_PLLON);
  while (!(RCC->CR & RCC_CR_PLLRDY)) {};
  // Select the PLL as the system clock source.
  RCC->CFGR &= ~(RCC_CFGR_SW);
  RCC->CFGR |= (RCC_CFGR_SW_PLL);
  while (!(RCC->CFGR & RCC_CFGR_SWS_PLL)) {};
}
/* USER CODE END 4 */

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */
  /* User can add his own implementation to report the HAL error return state */

  /* USER CODE END Error_Handler_Debug */
}

#ifdef  USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(char *file, uint32_t line)
{ 
  /* USER CODE BEGIN 6 */
  /* User can add his own implementation to report the file name and line number,
     tex: printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */

/************************ (C) COPYRIGHT STMicroelectronics *****END OF FILE****/
