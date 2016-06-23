#include <ets_sys.h>
#include <osapi.h>
#include <os_type.h>
#include <gpio.h>
#include <user_interface.h>
#include <upgrade.h>
#include <espconn.h>
#include <mem.h>
#include <spi_flash.h>
#include <driver\uart.h>
#include "user_config.h"

#define pheadbuffer "User-Agent: Mozilla/5.0 (Windows NT 10.0; WOW64; rv:46.0) Gecko/20100101 Firefox/46.0\r\n\
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n\
Accept-Language: en-US,en;q=0.5\r\n\
Accept-Encoding: gzip, deflate\r\n\
DNT: 1\r\n\
Connection: keep-alive\r\n\r\n"

// Global Vars.
LOCAL struct upgrade_server_info fota;
LOCAL struct espconn conn1; // For FOTA
LOCAL struct espconn conn2; // Open port 60000 and listen for incoming commands.
LOCAL struct espconn conn3; // Heartbeat Server on UDP port 60000
LOCAL esp_tcp tcp1;
LOCAL uint8_t *pConn1Data = NULL;
LOCAL char *otaBin[] = {"user1.bin", "user2.bin"};
LOCAL const uint16_t appVer = 0x000A; // Use this to keep track of firmware version (temporary feature).
LOCAL char hbData[15]; // To be filled with Sig. [1B], Rsvd. [1B], Fw. Version [2B], IP Addr. [4B], MAC Addr [6B], CHKSUM [1B]

// Function Prototypes
static void ICACHE_FLASH_ATTR otaCB (void *arg);
static void ICACHE_FLASH_ATTR startFOTA(void);
static void ICACHE_FLASH_ATTR cmdServerRecvCB(void *arg, char *pdata, unsigned short len);
static void ICACHE_FLASH_ATTR cmdHBRecvCB(void *arg, char *pdata, unsigned short len);
static void ICACHE_FLASH_ATTR setupServers(void);
static void ICACHE_FLASH_ATTR wifiEventCB(System_Event_t *event);
static void ICACHE_FLASH_ATTR initDone();
static void ICACHE_FLASH_ATTR configGPIO(void);

void user_rf_pre_init(void){} // You must have this.

/*
 * Something like main function. Any time consuming task should not be executed in this function.
 */
void user_init(void)
{

	system_set_os_print(1); // Set to '0' if you don't want it to print messages.
	uart_init(BIT_RATE_115200, BIT_RATE_115200);

	gpio_init();

	wifi_station_set_auto_connect(1); // disable auto-connect
	os_printf("SDK Version : %s!\n", system_get_sdk_version());

	configGPIO();

	// Register Handler for WiFi events.
	wifi_set_event_handler_cb(wifiEventCB);

	system_init_done_cb(&initDone);

}


/*
 * This is the OTA callback. If the upgrade is successful, then we should do a system
 * reboot to switch to the new firmware.
 */
static void ICACHE_FLASH_ATTR
otaCB (void *arg)
{
	struct upgrade_server_info *server = arg;
	struct espconn *pespconn = server->pespconn;

    if (server->upgrade_flag == true) {
        os_printf("Fw upgraded successfully. Rebooting.\n");
        system_upgrade_reboot();
    }
    else
    	os_printf("Fw upgrade failed\n");

    os_free(pConn1Data);
    pConn1Data = NULL;
}

/*
 * Initiates the FOTA upgrade.
 * This function will create a connection with the FOTA server.
 * Ensure that FOTA_SERVER has been defined with the FOTA server IP.
 */
static void ICACHE_FLASH_ATTR
startFOTA(void)
{
	conn1.type = ESPCONN_TCP;
	conn1.state = ESPCONN_NONE; // Init state
	tcp1.local_port = espconn_port(); // Assign unused port
	struct ip_info ipconfig;
	wifi_get_ip_info(STATION_IF, &ipconfig);
	os_memcpy(tcp1.local_ip, &ipconfig.ip, 4);
	*((uint32 *)tcp1.remote_ip) = ipaddr_addr(FOTA_SERVER);

	tcp1.remote_port = 80; // Get firmware
	conn1.proto.tcp = &tcp1;

	os_printf("Performing FW upgrade Over The Air!");
	if(pConn1Data == NULL)
	{
		pConn1Data = (uint8 *) os_zalloc(512); // Allocate dynamic memory
		if(pConn1Data == NULL)
		{
			os_printf("In startFOTA, failed to allocate memory (pConn1Data).\n");
			return;
		}
	}
	else
	{
		os_printf("In startFOTA, pConn1Data is not NULL!.\n");
		return;
	}

	os_sprintf(pConn1Data, "GET /%s HTTP/1.1\r\nHost: "IPSTR":80\r\n"pheadbuffer"",
			otaBin[system_upgrade_userbin_check() == UPGRADE_FW_BIN1 ? UPGRADE_FW_BIN2 : UPGRADE_FW_BIN1],
			IP2STR( (uint8_t *)(conn1.proto.tcp->remote_ip) ));

	// Perform OTA
	fota.port = 80;
	fota.check_times = 10000; // in ms
	fota.check_cb = otaCB;
	fota.pespconn = &conn1;
	fota.url = pConn1Data;

	*((uint32 *)fota.ip) = ipaddr_addr(FOTA_SERVER);

	system_upgrade_start(&fota);
}

/*
 * [SIG.][LENGTH][CMD][D0][D1][D2][D3][...][D(LENGTH-2]
 * CMD	:	0x00	->	ECHO
 * 			0x01	->	DIGITAL OUTPUT SET [TYP: 1 Data byte but may change. Use LENGTH to check.]
 * 						GPIO to bit mapping:
 * 						GPIO0: b0 of D0
 * 						GPIO1: b1 of D0
 * 						GPIO2: b2 of D0
 * 						...
 * 			0x02	->	DIGITAL OUTPUT CLEAR [TYP: 1 Data byte but may change. Use LENGTH to check.]
 *						See 0x01 for GPIO to bit mapping.
 *
 * 			0x80	->	INITIATE FOTA
 */
static void ICACHE_FLASH_ATTR
cmdServerRecvCB(void *arg, char *pdata, unsigned short len)
{
	int i;
	struct espconn *conn = (struct espconn *)arg;
	os_printf("Data received on conn2.\n");
	os_printf("Data: ");
	for(i = 0; i < len; i++) os_printf("%02X ", pdata[i]);
	os_printf("\n\n");
	// Assume that the data is not fragmented (Not many bytes being sent anyway...).
	//
	if(pdata[0] == 0xAA) // Signature Byte
	{
		// Valid packet.
		// I'm not checking packet length at the moment.
		i = pdata[1];
		switch(pdata[2])
		{
			case 0x00: // Echo.
				espconn_send(conn, pdata, len); //
				break;
			case 0x01:
				// This command is for controlling digital pins. We will only consider D0 byte.
				// Any bit that is set in the data byte will make that particular GPIO pin set
				// to HIGH level.
				if((((uint8_t)pdata[3] & (uint8_t)BIT0) != 0x00)) GPIO_OUTPUT_SET(0, 1);
				//if((((uint8_t)pdata[3] & (uint8_t)BIT1) != 0x00)) GPIO_OUTPUT_SET(1, 1);
				if((((uint8_t)pdata[3] & (uint8_t)BIT2) != 0x00)) GPIO_OUTPUT_SET(2, 1);
				break;
			case 0x02:
				// This command is for for controlling digital pins. We will only consider D0 byte.
				// Any bit that is set in the data byte will make that particular GPIO pin set
				// to LOW level.
				if((((uint8_t)pdata[3] & (uint8_t)BIT0) != 0x00)) GPIO_OUTPUT_SET(0, 0);
				//if((((uint8_t)pdata[3] & (uint8_t)BIT1) != 0x00)) GPIO_OUTPUT_SET(1, 0);
				if((((uint8_t)pdata[3] & (uint8_t)BIT2) != 0x00)) GPIO_OUTPUT_SET(2, 0);
				break;
			case 0x80:
				// Initiate FOTA
				startFOTA();
				break;
			default:
				os_printf("Invalid or unsupported operation for CMD = %02X!\n", pdata[0]);
				break;
		}
	}
}

/*
 * Callback function for HB Server (UDP). Once a valid
 * packet has been received, we should response with the
 * following packet structure.
 *
 * [SIG. 1B][RSVD. 1B][FW. VER. 2B][IPv4 4B][MAC ADDR. 6B][CHKSUM 1B]
 */
static void ICACHE_FLASH_ATTR
cmdHBRecvCB(void *arg, char *pdata, unsigned short len)
{
	int i;
	struct espconn *conn = (struct espconn *)arg;

    remot_info *premot = NULL;
    sint8 value = ESPCONN_OK;
    if (espconn_get_connection_info(conn,&premot,0) == ESPCONN_OK)
    {
    	//os_printf("Sending Datagram.\n");
    	conn->proto.udp->remote_port = premot->remote_port;
    	conn->proto.udp->remote_ip[0] = premot->remote_ip[0];
    	conn->proto.udp->remote_ip[1] = premot->remote_ip[1];
    	conn->proto.udp->remote_ip[2] = premot->remote_ip[2];
    	conn->proto.udp->remote_ip[3] = premot->remote_ip[3];
    	if(len == 2 && (pdata[0] == 0xAA && pdata[1] == 0x55))
    	{
    		value = espconn_send(conn, hbData, sizeof(hbData)); // Respond
    	}

    }
}

/*
 * Configures the Command Server (TCP) as well as the HeartBeat Server (UDP).
 * Basically, this function opens two ports and listens for incoming connections.
 * The corresponding callback function will be notified when a connection arrives.
 */
static void ICACHE_FLASH_ATTR
setupServers(void)
{
	// Listen for incoming connection on TCP port 60000
	os_printf("Establishing a TCP listening port with conn2.\n");
	conn2.proto.tcp = (esp_tcp *) os_zalloc(sizeof(esp_tcp));
	struct ip_info ipconfig;
	wifi_get_ip_info(STATION_IF, &ipconfig);
	os_memcpy(conn2.proto.tcp->local_ip, &ipconfig.ip, 4);
	conn2.proto.tcp->local_port = 60000;
	conn2.state = ESPCONN_NONE;
	conn2.type = ESPCONN_TCP;
	espconn_regist_recvcb(&conn2, cmdServerRecvCB);
	espconn_accept(&conn2);

	// Setup HeartBeat server
	os_printf("Establishing a UDP listening port with conn3.\n");
	conn3.proto.udp = (esp_udp *) os_zalloc(sizeof(esp_udp));
	os_memcpy(conn3.proto.tcp->local_ip, &ipconfig.ip, 4);
	conn3.proto.tcp->local_port = 60000;
	conn3.state = ESPCONN_NONE;
	conn3.type = ESPCONN_UDP;
	espconn_regist_recvcb(&conn3, cmdHBRecvCB);
	espconn_create(&conn3);
}

/*
 * Here, we can get notified when specific WiFi event has occurred.
 * This can be useful if we wish to do something related to an
 * event.
 */
static void ICACHE_FLASH_ATTR
wifiEventCB(System_Event_t *event)
{
	uint8_t i;
	uint8_t checksum;
	uint8_t sta_mac_addr[6];
	switch(event->event)
	{
		case EVENT_STAMODE_CONNECTED:
			os_printf("Connected to WiFi Access Point.\n");
			break;
		case EVENT_STAMODE_GOT_IP:
			// Start client
			os_printf("Received IP (%d.%d.%d.%d) from Access Point.\n", IP2STR(&(event->event_info.got_ip.ip.addr)));
			setupServers();

			// Fill  hbData
			hbData[0] = 0x55; // Signature Byte
			hbData[1] = 0; // Reserved.

			// Firmware Version
			hbData[2] = (uint8_t) appVer >> 8;
			hbData[3] = (uint8_t) appVer & 0xff;

			// Set IP Address
			hbData[4] = ip4_addr1(&(event->event_info.got_ip.ip.addr));
			hbData[5] = ip4_addr2(&(event->event_info.got_ip.ip.addr));
			hbData[6] = ip4_addr3(&(event->event_info.got_ip.ip.addr));
			hbData[7] = ip4_addr4(&(event->event_info.got_ip.ip.addr));

			// Set Station MAC Address
			wifi_get_macaddr(STATION_IF, sta_mac_addr);
			for(i = 8; i <= 13; i++)
				hbData[i] = sta_mac_addr[i-8];

			// Checksum. Just add...
			checksum = hbData[0];
			for(i = 1; i < (sizeof(hbData)-1); i++) checksum += hbData[i];

			hbData[14] = checksum; // Populate checksum byte

			break;
	}
}

/*
 * Configures WiFi mode and sets WiFi credentials.
 */
static void ICACHE_FLASH_ATTR
initDone()
{
	// Set to station mode
	wifi_set_opmode_current(STATION_MODE);
	struct station_config stationConfig;
	strncpy(stationConfig.ssid, WIFI_SSID, 32);
	strncpy(stationConfig.password, WIFI_PASSWD, 64);
	wifi_station_set_config(&stationConfig);
	wifi_station_connect();

}

/*
 * Configures the GPIO pins. Also, sets the default
 * level.
 */
static void ICACHE_FLASH_ATTR
configGPIO(void)
{
	/*
	 * GPIO0 & GPIO2 needs to be HIGH on power up (boot) for normal
	 * operation (i.e. execute code from flash).
	 */
	PIN_FUNC_SELECT(PERIPHS_IO_MUX_GPIO2_U, FUNC_GPIO2);
	GPIO_OUTPUT_SET(2, 1); // GPIO2 as output. Set to HIGH.

//	PIN_FUNC_SELECT(PERIPHS_IO_MUX_U0TXD_U, FUNC_GPIO1);
//	GPIO_OUTPUT_SET(1, 0); // GPIO1 or U0TXD will serve as output.

	PIN_FUNC_SELECT(PERIPHS_IO_MUX_GPIO0_U, FUNC_GPIO0);
	GPIO_OUTPUT_SET(0, 1); // GPIO0 as output. Set to HIGH.

//	PIN_FUNC_SELECT(PERIPHS_IO_MUX_U0RXD_U, FUNC_GPIO3);
//	GPIO_DIS_OUTPUT(3); // GPIO3 or U0RXD will serve as input.
}

