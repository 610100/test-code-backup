// test.cpp : �������̨Ӧ�ó������ڵ㡣
//

#include "stdafx.h"
#include <conio.h>
#include <tchar.h>

#include <Windows.h>
#include <iostream>
using namespace std;
//
//int _tmain(int argc, _TCHAR* argv[])
//{
//	return 0;
//}

//��ntsd�õ������DMP
LONG WINAPI ExpFilter1(struct _EXCEPTION_POINTERS *pExp)
{
	char szExec[256];
	c:\dbgtools\ntsd.exe -p %ld -e %ld -g -c ".dump c:\dumps\jit.dmp;q" 
	sprintf(szExec, "ntsd -c \".dump /f 123.dmp;q\" -p %d", 
		::GetCurrentProcessId());

	WinExec(szExec, SW_SHOWNORMAL);

	Sleep(1000);

	return EXCEPTION_EXECUTE_HANDLER;
}

#include <DbgHelp.h>
#pragma comment(lib, "Dbghelp.lib")
//��Dbghelp.dll�ṩ��MiniDumpWriteDump����ȡ�ó����DMP
LONG WINAPI ExpFilter2(struct _EXCEPTION_POINTERS *pExp)
{
	HANDLE hFile = ::CreateFile(
		_T("123.dmp"), 
		GENERIC_WRITE, 
		0, 
		NULL, 
		CREATE_ALWAYS, 
		FILE_ATTRIBUTE_NORMAL, 
		NULL);
	if(INVALID_HANDLE_VALUE != hFile)
	{
		MINIDUMP_EXCEPTION_INFORMATION einfo;
		einfo.ThreadId			= ::GetCurrentThreadId();
		einfo.ExceptionPointers	= pExp;
		//einfo.ClientPointers	= FALSE;
		einfo.ClientPointers	= true;
		MINIDUMP_TYPE mdt       = (MINIDUMP_TYPE)(MiniDumpWithPrivateReadWriteMemory | 
			MiniDumpWithDataSegs | 
			MiniDumpWithHandleData |
			MiniDumpWithFullMemoryInfo | 
			MiniDumpWithThreadInfo | 
			MiniDumpWithUnloadedModules ); 
		WriteDump
		::MiniDumpWriteDump(
			::GetCurrentProcess(), 
			::GetCurrentProcessId(), 
			hFile, 
			mdt, //MiniDumpWithFullMemory
			&einfo, 
			NULL, 
			NULL);
		::CloseHandle(hFile);
	}

	return EXCEPTION_EXECUTE_HANDLER;
}


LONG WINAPI ExpFilter(struct _EXCEPTION_POINTERS *pExp)
{
	cout << "Unhandled Exception!!!" << endl;

	return EXCEPTION_EXECUTE_HANDLER;
}


void StartUnhandledExceptionFilter()
{
	::SetUnhandledExceptionFilter(ExpFilter2);
}

int main()
{	
	cout << "begin !" << endl;

	StartUnhandledExceptionFilter();

	int i = 0;
	i = i / i;

	cout << "end !" << endl;

	getch();

	return 0;
}