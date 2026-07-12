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
  if (rx_data[0] == 0x01) {
    if (rx_data[1] > 13 && len == 5) {
      neopixel_set_all_color(rx_data[2] << 8 | rx_data[3] << 16 | rx_data[4]);
    }
    else {
      neopixel_set_color(rx_data[1], rx_data[2] << 8 | rx_data[3] << 16 | rx_data[4]);
    }
    neopixel_show();
  }
  else if (rx_data[0] == 0x00) {
    i2c1_set_send_data((uint8_t *)&uiAdcValue, 2);
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
  while (1)
  {
    HAL_Delay(10);

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
