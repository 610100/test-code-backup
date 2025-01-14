#include "arpPkt.h"
#include <iostream>
using namespace std;
//#include <./pcap.h>

#include "pcap.h"

pcap_if_t *g_palldevs;
pcap_if_t *g_pd;
int g_iCount = 0, g_num;                //第几个网络适配器
pcap_t *g_adhandle;                     //指向分配的空间
char g_errbuf[PCAP_ERRBUF_SIZE];        //错误信息
arp_packet g_arpPacket;                 //定义ARPPACKET结构体变量

unsigned char tmp_dest_ip[4] = {0, 0, 0, 0}; //目的ip
unsigned char tmp_sour_ip[4] = {0, 0, 0, 0}; //自身ip
unsigned char tmp_sour_addr[6] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00}; //发送方(源)mac 可随意修改
void setpkt();         //初始化packet
void sendPkt();        //发送并接收arp packet
void GetMACaddress();

void packet_handler(u_char *param, const struct pcap_pkthdr *header, const u_char *pkt_data);//接收到arp packet处理

void main ()
{
    printf("获取本机网络设备列表\n");
    //获得本地的网卡列表
    if(pcap_findalldevs(&g_palldevs, g_errbuf) == -1) //获得网络设备指针
    {
        cout << "Error in pcap_findalldevs:" << endl;
        return ;
    }
    printf("打印网络设备列表\n");
    // 显示网卡列表
    for(g_pd = g_palldevs; g_pd; g_pd = g_pd->next)
    {
        ++g_iCount;
        cout << g_iCount << ":name:" << g_pd->name << endl;
        if (g_pd->description)
            cout << "description:" << g_pd->description << endl;
        else
            cout << "No description available)\n";
    }
    if(g_iCount == 0)
    {
        cout << "\nNo interfaces found! Make sure WinPcap is installed.\n";
        return ;//没有发现网卡信息
    }
    printf("选择网络设备接口\n");
    cout << "Enter the interface number:(1-" << g_iCount << ")";
    cin >> g_num;

    if(g_num < 1 || g_num > g_iCount)
    {
        cout << "\nInterface number out of range.\n";
        /* 释放内存 */
        pcap_freealldevs(g_palldevs);
        return ;
    }
    printf("跳转到选中的适配器\n");
    /* 转到选择的网卡 */
    for(g_pd = g_palldevs, g_iCount = 0; g_iCount < g_num - 1 ; g_pd = g_pd->next, g_iCount++);
    printf("打开设备\n");
    /* 打开设备 */
    if ( (g_adhandle = pcap_open_live(g_pd->name,         // name of the device
                                      65536,            // portion of the packet to capture
                                      // 65536 guarantees that the whole packet will be captured on all the link layers
                                      1,                // promiscuous mode
                                      1000,             // read timeout
                                      g_errbuf            // error buffer
                                     ) ) == NULL)
    {
        cout << "\nUnable to open the adapter. " << g_pd->name << "is not supported by WinPcap\n";
        /* Free the device list */
        pcap_freealldevs(g_palldevs);
        return ;
    }

    if(g_pd->addresses == NULL)
    {
        cout << "Unable to open the adapter:" << g_pd->name << endl;
        return;
    }
    for(g_iCount = 0; g_iCount < 4; g_iCount++)
    {
        tmp_sour_ip[g_iCount] = g_pd->addresses->addr->sa_data[g_iCount + 2];
        tmp_dest_ip[g_iCount] = g_pd->addresses->addr->sa_data[g_iCount + 2] & g_pd->addresses->netmask->sa_data[g_iCount + 2];
    }
    cout << "this pc's ip and mac:\nip:";
    for(g_iCount = 0; g_iCount < 4; g_iCount++)
    {
        cout << dec << (int)tmp_sour_ip[g_iCount];
        if(g_iCount != 3)
            cout << ".";
    }
    cout << endl << "the results:(ctrl+c to quit)\n";
    GetMACaddress();
    setpkt();//初始packet
    sendPkt();//发送arp请求，并监听arp响应
}

void sendPkt()
{
    for(g_iCount = 1; g_iCount < 256; g_iCount++)
    {
        g_arpPacket.arp.dest_ip[3] = (unsigned char)g_iCount;
        if (pcap_sendpacket(g_adhandle, (unsigned char *)&g_arpPacket, sizeof(g_arpPacket) ) != 0) //发送arp 请求报
        {
            cout << "\nError sending the packet: \n";
            return;
        }
        pcap_loop(g_adhandle, 1, packet_handler, NULL);//接受arp相应包并且做出处理
    }
    cout << "send ok!" << endl;
}

//初始化packet
void setpkt()
{
    //设置初始arppkt的数据
    memset(&g_arpPacket, 0, sizeof(arp_packet)); // 数据包初始化

	 //自动填充的字段
	g_arpPacket.eth.eh_type = htons((unsigned short)0x0806); // DLC Header的以太网类型
	for(int i = 0; i < sizeof(g_arpPacket.eth.dest_mac); i++)
		g_arpPacket.eth.dest_mac[i] = 0xff;                         //广播地址   目的地址 如果未找到则局域网群发
    memcpy(g_arpPacket.eth.source_mac, tmp_sour_addr, sizeof(tmp_sour_addr)); //发送方（源）MAC

	g_arpPacket.arp.hardware_type = htons((unsigned short)1);;      // 硬件类型
	g_arpPacket.arp.protocol_type = htons((unsigned short)0x0800);  // 上层协议类型
    g_arpPacket.arp.add_len = (unsigned char)6;                     //mac长度
    g_arpPacket.arp.pro_len = (unsigned char)4;                     //ip长度
    g_arpPacket.arp.option = htons((unsigned short)0x1);            //1为arp请求 2为应答


    //sour ip and mac

    memcpy(g_arpPacket.arp.sour_addr, tmp_sour_addr, sizeof(tmp_sour_addr));  //发送方MAC
    memcpy(g_arpPacket.arp.sour_ip, tmp_sour_ip, sizeof(tmp_sour_ip));        //发送方ip

    memcpy(g_arpPacket.arp.dest_ip, tmp_dest_ip, sizeof(tmp_dest_ip));        //目的IP

	//询问包  目标MAC未指定
}

/* Callback function invoked by libpcap for every incoming packet */
void packet_handler(u_char *param, const struct pcap_pkthdr *header, const u_char *pkt_data)
{
    ethernet_head *PETHDR;
    arp_head *PARPHDR;

    //retireve the position of the ethernet header
    PETHDR = (ethernet_head *)pkt_data;
    if((PETHDR->eh_type) == 0x0608) //arp data
    {
        //retireve the position of the arp header
        PARPHDR = (arp_head *)(pkt_data + 14);

        if(PARPHDR->option == 0x0200) //对应答进行操作
        {
            cout << "ip:\t";
            for(int i = 0; i < 4; i++)
            {
                cout << dec << (int)PARPHDR->sour_ip[i];
                if(i != 3)
                    cout << ".";
            }
            cout << "\tmac:\t";
            for(g_iCount = 0; g_iCount < 6; g_iCount++)
            {
                if((int)PARPHDR->sour_addr[g_iCount] < 16)//显示ip
                    cout << "0";
                cout << hex << (int)PARPHDR->sour_addr[g_iCount]; //显示mac
                if(g_iCount != 5)
                    cout << "-";
            }
            //for(int i = 0; i < 6; i++)
            //{
            //    if((int)PARPHDR->sour_addr[i] < 16)//显示ip
            //        cout << "0";
            //    cout << hex << (int)PARPHDR->sour_addr[i]; //显示mac
            //    if(i != 5)
            //        cout << "-";
            //}

            cout << endl;
        }
    }
}

void GetMACaddress(void)
{
    unsigned char MACData[8];						// Allocate data structure for MAC (6 bytes needed)

    WKSTA_TRANSPORT_INFO_0 *pwkti;					// Allocate data structure for Netbios
    DWORD dwEntriesRead;
    DWORD dwTotalEntries;
    BYTE *pbBuffer;

	//当本计算机有可用的网卡，且已经连接上网络时，调用本函数才能成功，否则获取不到任何信息
	//通过 NetBIOS的枚举函数获取MAC地址
    // Get MAC address via NetBios's enumerate function
    NET_API_STATUS dwStatus = NetWkstaTransportEnum(
                                  NULL,						// [in]  server name 服务器名，0指本机
                                  0,							// [in]  data structure to return0指函数返回指向WKSTA_TRANSPORT_INFO_0结构的指针
								  //接受_WKSTA_TRANSPORT_INFO_0记录数组的缓冲区，有此函数自行分配，但使用完后要用下面定义的NetApiBufferFree函数释放内存
                                  &pbBuffer,					// [out] pointer to buffer
								  MAX_PREFERRED_LENGTH,		// [in]  maximum length缓冲区最大长度，传递上面定义的MAX_PREFERRED_LENGTH常量即可
                                  &dwEntriesRead,				// [out] counter of elements actually enumerated 用于记录实际元素个数
                                  &dwTotalEntries,			// [out] total number of elements that could be enumerated
								  NULL);						// [in/out] resume handle //恢复句柄

    assert(dwStatus == NERR_Success);

    pwkti = (WKSTA_TRANSPORT_INFO_0 *)pbBuffer;		// type cast the buffer

    for(DWORD i = 1; i < dwEntriesRead; i++)			// first address is 00000000, skip it
    {
        // enumerate MACs and print
        swscanf((wchar_t *)pwkti[i].wkti0_transport_address, L"%2hx%2hx%2hx%2hx%2hx%2hx",
                &MACData[0], &MACData[1], &MACData[2], &MACData[3], &MACData[4], &MACData[5]);
        printf("mac: %02X-%02X-%02X-%02X-%02X-%02X\n",
               MACData[0], MACData[1], MACData[2], MACData[3], MACData[4], MACData[5]);
        for(int i = 0; i < 6; i++)
            tmp_sour_addr[i] = (int)MACData[i];
    }

	//释放NetWkstaTransportEnum函数定义的内存
    // Release pbBuffer allocated by above function
    dwStatus = NetApiBufferFree(pbBuffer);
    assert(dwStatus == NERR_Success);
}