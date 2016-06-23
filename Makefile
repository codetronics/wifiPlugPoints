#
# Makefile for esp-link - https://github.com/jeelabs/esp-link
#
# Makefile heavily adapted to esp-link and wireless flashing by Thorsten von Eicken
# Lots of work, in particular to support windows, by brunnels
# Original from esphttpd and others...
 VERBOSE=0
 
# Removed some part that might be confusing because it is not being used in this particular project.

# --------------- toolchain configuration ---------------

# Base directory for the compiler. Needs a / at the end.
# Typically you'll install https://github.com/pfalcon/esp-open-sdk
XTENSA_TOOLS_ROOT ?= c:/Espressif/xtensa-lx106-elf/bin/

# Firmware version 
# WARNING: if you change this expect to make code adjustments elsewhere, don't expect
# that esp-link will magically work with a different version of the SDK!!!
SDK_VERS ?= esp_iot_sdk_v1.5.4

# Try to find the firmware manually extracted, e.g. after downloading from Espressif's BBS,
# http://bbs.espressif.com/viewforum.php?f=46
SDK_BASE ?= c:/Espressif/ESP8266_SDK

# If the firmware isn't there, see whether it got downloaded as part of esp-open-sdk
#ifeq ($(SDK_BASE),)
#SDK_BASE := $(wildcard $(XTENSA_TOOLS_ROOT)/../../$(SDK_VERS))
#endif

# Clean up SDK path
#SDK_BASE := c:/Espressif/ESP8266_SDK
#$(warning Using SDK from $(SDK_BASE))

# Path to bootloader file
BOOTFILE	?= $(SDK_BASE)/bin/boot_v1.5.bin
# Path to blank.bin file.
BLANKFILE	?= $(SDK_BASE)/bin/blank.bin

# Esptool.py path and port, only used for 1-time serial flashing
# Typically you'll use https://github.com/themadinventor/esptool
# Windows users use the com port i.e: ESPPORT ?= com3
ESPTOOL		?= C:/Espressif/utils/esptool.exe
ESPPORT		?= COM3
ESPBAUD		?= 1000000

# www directory location
WWW_DIR		?= D:/wamp64/www

# --------------- chipset configuration   ---------------

# Pick your flash size: "512KB", "1MB", or "4MB"
FLASH_SIZE ?= 1MB

# --------------- esp-link modules config options ---------------

# Optional Modules mqtt
#MODULES ?= mqtt rest syslog

# -------------- End of config options -------------

ESP_FLASH_MAX       ?= 503808  # max bin file

ifeq ("$(FLASH_SIZE)","512KB")
# Winbond 25Q40 512KB flash, typ for esp-01 thru esp-11
ESP_SPI_SIZE        ?= 0       # 0->512KB (256KB+256KB)
ESP_FLASH_MODE      ?= 0       # 0->QIO
ESP_FLASH_FREQ_DIV  ?= 0       # 0->40Mhz
ET_FS               ?= 4m      # 4Mbit flash size in esptool flash command
ET_FF               ?= 40m     # 40Mhz flash speed in esptool flash command
ET_BLANK            ?= 0x7E000 # where to flash blank.bin to erase wireless settings

else ifeq ("$(FLASH_SIZE)","1MB")
# ESP-01E
ESP_SPI_SIZE        ?= 2       # 2->1MB (512KB+512KB)
ESP_FLASH_MODE      ?= 0       # 0->QIO
ESP_FLASH_FREQ_DIV  ?= 15      # 15->80MHz
ET_FS               ?= 8m      # 8Mbit flash size in esptool flash command
ET_FF               ?= 80m     # 80Mhz flash speed in esptool flash command
ET_BLANK            ?= 0xFE000 # where to flash blank.bin to erase wireless settings

else ifeq ("$(FLASH_SIZE)","2MB")
# Manuf 0xA1 Chip 0x4015 found on wroom-02 modules
# Here we're using two partitions of approx 0.5MB because that's what's easily available in terms
# of linker scripts in the SDK. Ideally we'd use two partitions of approx 1MB, the remaining 2MB
# cannot be used for code (esp8266 limitation).
ESP_SPI_SIZE        ?= 4       # 6->4MB (1MB+1MB) or 4->4MB (512KB+512KB)
ESP_FLASH_MODE      ?= 0       # 0->QIO, 2->DIO
ESP_FLASH_FREQ_DIV  ?= 15      # 15->80Mhz
ET_FS               ?= 16m     # 16Mbit flash size in esptool flash command
ET_FF               ?= 80m     # 80Mhz flash speed in esptool flash command
ET_BLANK            ?= 0x1FE000 # where to flash blank.bin to erase wireless settings

else
# Winbond 25Q32 4MB flash, typ for esp-12
# Here we're using two partitions of approx 0.5MB because that's what's easily available in terms
# of linker scripts in the SDK. Ideally we'd use two partitions of approx 1MB, the remaining 2MB
# cannot be used for code (esp8266 limitation).
ESP_SPI_SIZE        ?= 4       # 6->4MB (1MB+1MB) or 4->4MB (512KB+512KB)
ESP_FLASH_MODE      ?= 0       # 0->QIO, 2->DIO
ESP_FLASH_FREQ_DIV  ?= 15      # 15->80Mhz
ET_FS               ?= 32m     # 32Mbit flash size in esptool flash command
ET_FF               ?= 80m     # 80Mhz flash speed in esptool flash command
ET_BLANK            ?= 0x3FE000 # where to flash blank.bin to erase wireless settings
endif

# Output directors to store intermediate compiled files
# relative to the project directory
BUILD_BASE	= build
FW_BASE		= firmware

# name for the target project
TARGET		= wifiPlugPoints

# espressif tool to concatenate sections for OTA upload using bootloader v1.2+
APPGEN_TOOL	?= C:\Espressif\utils\gen_appbin.py

CFLAGS=

# set defines for optional modules
ifneq (,$(findstring mqtt,$(MODULES)))
	CFLAGS		+= -DMQTT
endif

ifneq (,$(findstring rest,$(MODULES)))
	CFLAGS		+= -DREST
endif

ifneq (,$(findstring syslog,$(MODULES)))
	CFLAGS		+= -DSYSLOG
endif

# which modules (subdirectories) of the project to include in compiling
LIBRARIES_DIR 	= libraries
MODULES		  	= user driver
MODULES			+= $(foreach sdir,$(LIBRARIES_DIR),$(wildcard $(sdir)/*))
EXTRA_INCDIR 	= include .

# libraries used in this project, mainly provided by the SDK
LIBS = c gcc hal phy pp net80211 wpa main lwip crypto upgrade

# compiler flags using during compilation of source files
CFLAGS += -Os -g -O2 -std=gnu90 -Wpointer-arith -Wundef -Werror -Wl,-EL -fno-inline-functions -nostdlib -mlongcalls -mtext-section-literals -mno-serialize-volatile -D__ets__ -DICACHE_FLASH

#CFLAGS	+= -Os -ggdb -std=gnu90 -Werror -Wpointer-arith -Wundef -Wall -Wl,-EL -fno-inline-functions \
		-nostdlib -mlongcalls -mtext-section-literals -ffunction-sections -fdata-sections \
		-D__ets__ -DICACHE_FLASH -Wno-address -DFIRMWARE_SIZE=$(ESP_FLASH_MAX) \
		-DMCU_RESET_PIN=$(MCU_RESET_PIN) -DMCU_ISP_PIN=$(MCU_ISP_PIN) \
		-DLED_CONN_PIN=$(LED_CONN_PIN) -DLED_SERIAL_PIN=$(LED_SERIAL_PIN) \
		-DVERSION="$(VERSION)"

# linker flags used to generate the main object file
LDFLAGS		= -nostdlib -Wl,--no-check-sections -u call_user_start -Wl,-static -Wl,--gc-sections

# linker script used for the above linker step
LD_SCRIPT 	:= build/eagle.esphttpd.v6.ld
LD_SCRIPT1	:= build/eagle.esphttpd1.v6.ld
LD_SCRIPT2	:= build/eagle.esphttpd2.v6.ld

# various paths from the SDK used in this project
SDK_LIBDIR		= lib
SDK_LDDIR		= ld
SDK_INCDIR		= include include/json
SDK_TOOLSDIR	= tools

# select which tools to use as compiler, librarian and linker
CC		:= $(XTENSA_TOOLS_ROOT)xtensa-lx106-elf-gcc
AR		:= $(XTENSA_TOOLS_ROOT)xtensa-lx106-elf-ar
LD		:= $(XTENSA_TOOLS_ROOT)xtensa-lx106-elf-gcc
OBJCP	:= $(XTENSA_TOOLS_ROOT)xtensa-lx106-elf-objcopy
OBJDP	:= $(XTENSA_TOOLS_ROOT)xtensa-lx106-elf-objdump


####
SRC_DIR		:= $(MODULES)
BUILD_DIR	:= $(addprefix $(BUILD_BASE)/,$(MODULES))

SDK_LIBDIR	:= $(addprefix $(SDK_BASE)/,$(SDK_LIBDIR))
SDK_LDDIR 	:= $(addprefix $(SDK_BASE)/,$(SDK_LDDIR))
SDK_INCDIR	:= $(addprefix -I$(SDK_BASE)/,$(SDK_INCDIR))
SDK_TOOLS	:= $(addprefix $(SDK_BASE)/,$(SDK_TOOLSDIR))
#APPGEN_TOOL	:= $(addprefix $(SDK_TOOLS)/,$(APPGEN_TOOL))

SRC			:= $(foreach sdir,$(SRC_DIR),$(wildcard $(sdir)/*.c))
OBJ			:= $(patsubst %.c,$(BUILD_BASE)/%.o,$(SRC))
LIBS		:= $(addprefix -l,$(LIBS))
APP_AR		:= $(addprefix $(BUILD_BASE)/,$(TARGET)_app.a)
USER1_OUT 	:= $(addprefix $(BUILD_BASE)/,$(TARGET).user1.out)
USER2_OUT 	:= $(addprefix $(BUILD_BASE)/,$(TARGET).user2.out)

INCDIR			:= $(addprefix -I,$(SRC_DIR))
EXTRA_INCDIR	:= $(addprefix -I,$(EXTRA_INCDIR))
MODULE_INCDIR	:= $(addsuffix /include,$(INCDIR))

V ?= $(VERBOSE)
ifeq ("$(V)","1")
Q :=
vecho := @true
else
Q := @
vecho := @echo
endif

vpath %.c $(SRC_DIR)

define compile-objects
$1/%.o: %.c
	$(vecho) "CC $$<"
	$(Q)$(CC) $(INCDIR) $(MODULE_INCDIR) $(EXTRA_INCDIR) $(SDK_INCDIR) $(CFLAGS)  -c $$< -o $$@
endef

.PHONY: all checkdirs clean webpages.espfs wiflash

all: echo_version checkdirs $(FW_BASE)/user1.bin $(FW_BASE)/user2.bin

echo_version:
	@echo SRC: $(SRC)
	
$(USER1_OUT): $(APP_AR) $(LD_SCRIPT1)
	$(vecho) "LD $@"
	$(Q) $(LD) -L$(SDK_LIBDIR) -T$(LD_SCRIPT1) $(LDFLAGS) -Wl,--start-group $(LIBS) $(APP_AR) -Wl,--end-group -o $@
#	@echo Dump  : $(OBJDP) -x $(USER1_OUT)
#	@echo Disass: $(OBJDP) -d -l -x $(USER1_OUT)
#	$(Q) $(OBJDP) -x $(TARGET_OUT) | egrep espfs_img

$(USER2_OUT): $(APP_AR) $(LD_SCRIPT2)
	$(vecho) "LD $@"
	$(Q) $(LD) -L$(SDK_LIBDIR) -T$(LD_SCRIPT2) $(LDFLAGS) -Wl,--start-group $(LIBS) $(APP_AR) -Wl,--end-group -o $@
#	$(Q) $(OBJDP) -x $(TARGET_OUT) | egrep espfs_img

$(FW_BASE):
	$(vecho) "FW $@"
	$(Q) mkdir -p $@

$(FW_BASE)/user1.bin: $(USER1_OUT) $(FW_BASE)
	$(Q) $(OBJCP) --only-section .text -O binary $(USER1_OUT) eagle.app.v6.text.bin
	$(Q) $(OBJCP) --only-section .data -O binary $(USER1_OUT) eagle.app.v6.data.bin
	$(Q) $(OBJCP) --only-section .rodata -O binary $(USER1_OUT) eagle.app.v6.rodata.bin
	$(Q) $(OBJCP) --only-section .irom0.text -O binary $(USER1_OUT) eagle.app.v6.irom0text.bin
#	ls -ls eagle*bin
	$(Q) $(APPGEN_TOOL) $(USER1_OUT) 2 $(ESP_FLASH_MODE) $(ESP_FLASH_FREQ_DIV) $(ESP_SPI_SIZE) 1
	$(Q) rm -f eagle.app.v6.*.bin
	$(Q) mv eagle.app.flash.bin $@
	@echo "** user1.bin uses $$(stat -c '%s' $@) bytes of" $(ESP_FLASH_MAX) "available"
#	$(Q) if [ $$(stat -c '%s' $@) -gt $$(( $(ESP_FLASH_MAX) )) ]; then echo "$@ too big!"; false; fi

$(FW_BASE)/user2.bin: $(USER2_OUT) $(FW_BASE)
	$(Q) $(OBJCP) --only-section .text -O binary $(USER2_OUT) eagle.app.v6.text.bin
	$(Q) $(OBJCP) --only-section .data -O binary $(USER2_OUT) eagle.app.v6.data.bin
	$(Q) $(OBJCP) --only-section .rodata -O binary $(USER2_OUT) eagle.app.v6.rodata.bin
	$(Q) $(OBJCP) --only-section .irom0.text -O binary $(USER2_OUT) eagle.app.v6.irom0text.bin
	$(Q) $(APPGEN_TOOL) $(USER2_OUT) 2 $(ESP_FLASH_MODE) $(ESP_FLASH_FREQ_DIV) $(ESP_SPI_SIZE) 2
	$(Q) rm -f eagle.app.v6.*.bin
	$(Q) mv eagle.app.flash.bin $@
#	$(Q) if [ $$(stat -c '%s' $@) -gt $$(( $(ESP_FLASH_MAX) )) ]; then echo "$@ too big!"; false; fi

$(APP_AR): $(OBJ)
	$(vecho) "AR $@"
	$(Q) $(AR) cru $@ $^

checkdirs: $(BUILD_DIR)
	
$(BUILD_DIR):
	$(Q) mkdir -p $@

wiflash: all
	./wiflash $(ESP_HOSTNAME) $(FW_BASE)/user1.bin $(FW_BASE)/user2.bin

baseflash: all
	$(Q) $(ESPTOOL) --port $(ESPPORT) --baud $(ESPBAUD) write_flash 0x01000 $(FW_BASE)/user1.bin

flash: all
	$(Q) $(ESPTOOL) --port $(ESPPORT) --baud $(ESPBAUD) write_flash -fs $(ET_FS) -ff $(ET_FF) \
	0x00000 "$(BOOTFILE)"
	$(Q) $(ESPTOOL) --port $(ESPPORT) --baud $(ESPBAUD) write_flash -fs $(ET_FS) -ff $(ET_FF)\
	0x01000 "$(FW_BASE)/user1.bin"
	$(Q) $(ESPTOOL) --port $(ESPPORT) --baud $(ESPBAUD) write_flash -fs $(ET_FS) -ff $(ET_FF)\
	0xFE000 "$(BLANKFILE)"

deploy: all
	$(Q) cp -f $(FW_BASE)/user2.bin $(WWW_DIR)/user2.bin
	$(Q) cp -f $(FW_BASE)/user1.bin $(WWW_DIR)/user1.bin

build/eagle.esphttpd1.v6.ld: $(SDK_LDDIR)/eagle.app.v6.new.1024.app1.ld
	$(Q) cp -f $(SDK_LDDIR)/eagle.app.v6.new.1024.app1.ld $@
build/eagle.esphttpd2.v6.ld: $(SDK_LDDIR)/eagle.app.v6.new.1024.app2.ld
	$(Q) cp -f $(SDK_LDDIR)/eagle.app.v6.new.1024.app2.ld $@

clean:
	$(Q) rm -f $(APP_AR)
	$(Q) rm -f $(TARGET_OUT)
	$(Q) find $(BUILD_BASE) -type f | xargs rm -f
#	$(Q) make -C espfs/mkespfsimage/ clean
	$(Q) rm -rf $(FW_BASE)
#	$(Q) rm -f webpages.espfs
	
$(foreach bdir,$(BUILD_DIR),$(eval $(call compile-objects,$(bdir))))