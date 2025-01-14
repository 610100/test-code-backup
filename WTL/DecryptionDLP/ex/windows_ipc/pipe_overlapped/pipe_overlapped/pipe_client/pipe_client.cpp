/* 头文件 */
#include "stdafx.h"

#include <windows.h> 
#include <stdio.h>
#include <conio.h>
#include <tchar.h>
/* 常量 */
#define BUFSIZE 512
/* ************************************
* int main(VOID) 
* 功能	pipe 通信服务端主函数
**************************************/
int main(int argc, TCHAR *argv[]) 
{ 
	HANDLE hPipe; 
	LPTSTR lpvMessage=TEXT("客户端默认发送消息！！！！！"); 
	TCHAR chBuf[BUFSIZE]; 
	BOOL fSuccess; 
	DWORD cbRead, cbWritten, dwMode; 
	LPTSTR lpszPipename = TEXT("\\\\.\\pipe\\samplenamedpipe"); 

	if( argc > 1 )	// 如果输入了参数，则使用输入的参数
		lpvMessage = argv[1];
	while (1) 
	{ 
		// 打开一个命名pipe
		hPipe = CreateFile( 
			lpszPipename,   // pipe 名 
			GENERIC_READ |   GENERIC_WRITE,		//  可读可写
			0,              // 不共享
			NULL,           // 默认安全属性
			OPEN_EXISTING,  // 已经存在（由服务端创建）
			0,              // 默认属性
			NULL);    
		if (hPipe != INVALID_HANDLE_VALUE) 
			break; 

		// 如果不是 ERROR_PIPE_BUSY 错误，直接退出  
		if (GetLastError() != ERROR_PIPE_BUSY) 
		{
			printf("Could not open pipe"); 
			return 0;
		}

		// 如果所有pipe实例都处于繁忙状态，等待2秒。
		if (!WaitNamedPipe(lpszPipename, 2000)) 
		{ 
			printf("Could not open pipe"); 
			return 0;
		} 
	} 

	// pipe已经连接，设置为消息读状态 
	dwMode = PIPE_READMODE_MESSAGE; 
	fSuccess = SetNamedPipeHandleState( 
		hPipe,    // 句柄
		&dwMode,  // 新状态
		NULL,     // 不设置最大缓存
		NULL);    // 不设置最长时间
	if (!fSuccess) 
	{
		printf("SetNamedPipeHandleState failed"); 
		return 0;
	}

	// 写入pipe
	fSuccess = WriteFile( 
		hPipe,                  // 句柄
		lpvMessage,             // 写入的内容
		(lstrlen(lpvMessage)+1)*sizeof(TCHAR), // 写入内容的长度
		&cbWritten,             // 实际写的内容
		NULL);                  // 非 overlapped 
	if (!fSuccess) 
	{
		printf("WriteFile failed"); 
		return 0;
	}

	do 
	{ 
		// 读回复 
		fSuccess = ReadFile( 
			hPipe,    // 句柄
			chBuf,    // 读取内容的缓存
			BUFSIZE*sizeof(TCHAR),  // 缓存大小
			&cbRead,  // 实际读的字节
			NULL);    // 非 overlapped 

		if (! fSuccess && GetLastError() != ERROR_MORE_DATA) 
			break; //失败，退出

		_tprintf( TEXT("%s\n"), chBuf ); // 打印读的结果
	} while (!fSuccess);  //  ERROR_MORE_DATA 或者成功则循环

	getch();//任意键退出
	// 关闭句柄
	CloseHandle(hPipe);  
	return 0; 
}