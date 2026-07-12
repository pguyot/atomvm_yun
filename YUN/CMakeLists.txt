cmake_minimum_required(VERSION 3.13)

set(CMAKE_TOOLCHAIN_FILE ${CMAKE_CURRENT_SOURCE_DIR}/cmake/arm-none-eabi.cmake
    CACHE FILEPATH "" )

project(yun C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE MinSizeRel)
endif()

set(HAL_DIR Drivers/STM32F0xx_HAL_Driver)
set(CMSIS_DIR Drivers/CMSIS)

add_executable(yun.elf
  Src/main.c
  Src/gpio.c
  Src/adc.c
  Src/i2c.c
  Src/stm32f0xx_it.c
  Src/stm32f0xx_hal_msp.c
  Src/system_stm32f0xx.c
  i2c_ex/i2c_ex.c
  sk6812/030-SK6812-Release/sk6812.c
  ${HAL_DIR}/Src/stm32f0xx_hal.c
  ${HAL_DIR}/Src/stm32f0xx_hal_cortex.c
  ${HAL_DIR}/Src/stm32f0xx_hal_rcc.c
  ${HAL_DIR}/Src/stm32f0xx_hal_rcc_ex.c
  ${HAL_DIR}/Src/stm32f0xx_hal_gpio.c
  ${HAL_DIR}/Src/stm32f0xx_hal_adc.c
  ${HAL_DIR}/Src/stm32f0xx_hal_adc_ex.c
  ${HAL_DIR}/Src/stm32f0xx_hal_i2c.c
  ${HAL_DIR}/Src/stm32f0xx_hal_i2c_ex.c
  ${HAL_DIR}/Src/stm32f0xx_hal_pwr.c
  ${HAL_DIR}/Src/stm32f0xx_hal_dma.c
  ${HAL_DIR}/Src/stm32f0xx_hal_flash.c
  ${HAL_DIR}/Src/stm32f0xx_hal_flash_ex.c
  ${CMSIS_DIR}/Device/ST/STM32F0xx/Source/Templates/gcc/startup_stm32f030x6.s
)

target_compile_definitions(yun.elf PRIVATE STM32F030x6 USE_HAL_DRIVER)

target_include_directories(yun.elf PRIVATE
  Inc
  ${CMAKE_CURRENT_SOURCE_DIR}      # main.c includes "i2c_ex/i2c_ex.h"
  i2c_ex                            # i2c_ex.c includes "i2c_ex.h"
  sk6812/030-SK6812-Release
  ${HAL_DIR}/Inc
  ${CMSIS_DIR}/Device/ST/STM32F0xx/Include
  ${CMSIS_DIR}/Include
)

set(LINKER_SCRIPT ${CMAKE_CURRENT_SOURCE_DIR}/STM32F030F4.ld)
target_link_options(yun.elf PRIVATE
  -T${LINKER_SCRIPT}
  -Wl,-Map=yun.map,--cref
)
set_target_properties(yun.elf PROPERTIES LINK_DEPENDS ${LINKER_SCRIPT})

add_custom_command(TARGET yun.elf POST_BUILD
  COMMAND ${CMAKE_SIZE} $<TARGET_FILE:yun.elf>
  COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:yun.elf> yun.bin
  COMMENT "Generating yun.bin"
)
