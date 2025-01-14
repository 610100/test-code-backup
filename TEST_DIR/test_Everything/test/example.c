
// Everything IPC test

#include <windows.h>
//#include <iostream>
//using namespace std;
#include <stdio.h>


#include "Everything-SDK\Everything_IPC.h"

#ifdef UNICODE
#define sendquery sendqueryW
#else
#define sendquery sendqueryA
#endif

#define COPYDATA_IPCTEST_QUERYCOMPLETEW	0
#define COPYDATA_IPCTEST_QUERYCOMPLETEA	1

DWORD starttime;

// query everything with search string
int sendqueryA(HWND hwnd,char *search_string)
{
	EVERYTHING_IPC_QUERY *query;
	int len;
	int size;
	HWND everything_hwnd;
	COPYDATASTRUCT cds;
	
	starttime = GetTickCount();
	
	everything_hwnd = FindWindow(EVERYTHING_IPC_WNDCLASS,0);
	if (everything_hwnd)
	{
		len = (int)strlen(search_string);
		
		size = sizeof(EVERYTHING_IPC_QUERY) - sizeof(CHAR) + len*sizeof(CHAR) + sizeof(CHAR);
		
		query = (EVERYTHING_IPC_QUERY *)HeapAlloc(GetProcessHeap(),0,size);//在指定的堆上分配内存
		if (query)
		{
			query->max_results = EVERYTHING_IPC_ALLRESULTS;
			query->offset = 0;
			query->reply_copydata_message = COPYDATA_IPCTEST_QUERYCOMPLETEA;
			query->search_flags = 0;
			query->reply_hwnd = hwnd;
			CopyMemory(query->search_string,search_string,(len+1)*sizeof(CHAR));
		
			cds.cbData = size;
			cds.dwData = EVERYTHING_IPC_COPYDATAQUERY;
			cds.lpData = query;

			if (SendMessage(everything_hwnd,WM_COPYDATA,(WPARAM)hwnd,(LPARAM)&cds) == TRUE)
			{
				printf("Query sent.\n");
				HeapFree(GetProcessHeap(),0,query);
				
				return 1;
			}
			else
			{
				printf("Everything IPC service not running.\n");
			}

			HeapFree(GetProcessHeap(),0,query);
		}
		else
		{
			printf("failed to allocate %d bytes for IPC query.\n",size);
		}
	}
	else
	{
		// the everything window was not found.
		// we can optionally RegisterWindowMessage("EVERYTHING_IPC_CREATED") and 
		// wait for Everything to post this message to all top level windows when its up and running.
		printf("Everything IPC window not found, IPC unavailable.\n");
	}

	return 0;
}

// query everything with search string
int sendqueryW(HWND hwnd,WCHAR *search_string)
{
	EVERYTHING_IPC_QUERY *query;
	int len;
	int size;
	HWND everything_hwnd;
	COPYDATASTRUCT cds;
	
	starttime = GetTickCount();
	
	everything_hwnd = FindWindow(EVERYTHING_IPC_WNDCLASS,0);
	if (everything_hwnd)
	{
		len = (int)wcslen(search_string);
		
		size = sizeof(EVERYTHING_IPC_QUERY) - sizeof(WCHAR) + len*sizeof(WCHAR) + sizeof(WCHAR);
		
		query = (EVERYTHING_IPC_QUERY *)HeapAlloc(GetProcessHeap(),0,size);
		if (query)
		{
			query->max_results = EVERYTHING_IPC_ALLRESULTS;
			query->offset = 0;
			query->reply_copydata_message = COPYDATA_IPCTEST_QUERYCOMPLETEW;
			query->search_flags = 0;
			query->reply_hwnd = hwnd;
			CopyMemory(query->search_string,search_string,(len+1)*sizeof(WCHAR));
		
			cds.cbData = size;
			cds.dwData = EVERYTHING_IPC_COPYDATAQUERY;
			cds.lpData = query;

			if (SendMessage(everything_hwnd,WM_COPYDATA,(WPARAM)hwnd,(LPARAM)&cds) == TRUE)
			{
				printf("Query sent.\n");
				HeapFree(GetProcessHeap(),0,query);
				
				return 1;
			}
			else
			{
				printf("Everything IPC service not running.\n");
			}

			HeapFree(GetProcessHeap(),0,query);
		}
		else
		{
			printf("failed to allocate %d bytes for IPC query.\n",size);
		}
	}
	else
	{
		// the everything window was not found.
		// we can optionally RegisterWindowMessage("EVERYTHING_IPC_CREATED") and 
		// wait for Everything to post this message to all top level windows when its up and running.
		printf("Everything IPC window not found, IPC unavailable.\n");
	}

	return 0;
}

void listresultsA(EVERYTHING_IPC_LIST *list)
{
	DWORD i;
	
	for(i=0;i<list->numitems;i++)
	{
		if (list->items[i].flags & EVERYTHING_IPC_DRIVE)
		{
			//cout<<"DRIVE "<<EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i])<<endl;
			printf("DRIVE %s\n",EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
		}
		else
		if (list->items[i].flags & EVERYTHING_IPC_FOLDER)
		{
			//cout<<"FOLDER "<<EVERYTHING_IPC_ITEMPATH(list,&list->items[i])<<EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i])<<endl;
			printf("FOLDER %s\\%s\n",EVERYTHING_IPC_ITEMPATH(list,&list->items[i]),EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
		}
		else
		{
			//cout<<"FILE "<<EVERYTHING_IPC_ITEMPATH(list,&list->items[i])<<EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i])<<endl;
			printf("FILE %s\\%s\n",EVERYTHING_IPC_ITEMPATH(list,&list->items[i]),EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
		}
	}
	
	printf("%d items (%f seconds)\n",list->numitems,(GetTickCount()-starttime)/1000.0f);
	PostQuitMessage(0);
}

void listresultsW(EVERYTHING_IPC_LIST *list)
{
	DWORD i;
	
	for(i=0;i<list->numitems;i++)
	{
		if (list->items[i].flags & EVERYTHING_IPC_DRIVE)
		{
			printf("DRIVE %S\n",EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
		}
		else
		if (list->items[i].flags & EVERYTHING_IPC_FOLDER)
		{
			wchar_t *p;
			
			p = EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]);
			
			while(*p)
			{
				printf("%d (%c)\n",*p,*p);
				p++;
			}
			
//			printf("FOLDER %S\\%S\n",EVERYTHING_IPC_ITEMPATH(list,&list->items[i]),EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
//			printf("FOLDER %S\\%S\n",EVERYTHING_IPC_ITEMPATH(list,&list->items[i]),EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
		}
		else
		{
			printf("FILE %S\\%S\n",EVERYTHING_IPC_ITEMPATH(list,&list->items[i]),EVERYTHING_IPC_ITEMFILENAME(list,&list->items[i]));
		}
	}
	
	printf("%d items (%f seconds)\n",list->numitems,(GetTickCount()-starttime)/1000.0f);
	PostQuitMessage(0);
}

// custom window proc
LRESULT __stdcall window_proc(HWND hwnd,UINT msg,WPARAM wParam,LPARAM lParam)
{
	switch(msg)
	{
		case WM_COPYDATA:
		{
			COPYDATASTRUCT *cds = (COPYDATASTRUCT *)lParam;
			
			switch(cds->dwData)
			{
				case COPYDATA_IPCTEST_QUERYCOMPLETEA:
					listresultsA((EVERYTHING_IPC_LIST *)cds->lpData);
					return TRUE;

				case COPYDATA_IPCTEST_QUERYCOMPLETEW:
					listresultsW((EVERYTHING_IPC_LIST *)cds->lpData);
					return TRUE;
			}
			
			break;
		}
	}
	
	return DefWindowProc(hwnd,msg,wParam,lParam);
}

// main entry
int main(int argc,char **argv)
{
	WNDCLASSEX wcex;
	HWND hwnd;
	MSG msg;
	int ret;
/*
{
	HINSTANCE ret;
	HANDLE h;
	WIN32_FIND_DATA fd;
	
	//CreateProcess
	
	h = FindFirstFile("E:\\WINDOWS\\system32\\gpedit.msc",&fd);
	if (h != INVALID_HANDLE_VALUE)
	{
		printf("found\n");
		FindClose(h);
	}
	else
	{
		printf("not found\n");
	}
	
	ret = ShellExecute(0,0,L"E:\\WINDOWS\\system32\\gpedit.msc",0,L"E:\\WINDOWS\\system32",SW_SHOWNORMAL);
	printf("exec %d\n",ret);
	return 0;
}
*/
	printf("Everything IPC test\n");

	ZeroMemory(&wcex,sizeof(wcex));
	wcex.cbSize = sizeof(wcex);
	
	if (!GetClassInfoEx(GetModuleHandle(0),TEXT("IPCTEST"),&wcex))
	{
		ZeroMemory(&wcex,sizeof(wcex));
		wcex.cbSize = sizeof(wcex);
		wcex.hInstance = GetModuleHandle(0);
		wcex.lpfnWndProc = window_proc;
		wcex.lpszClassName = TEXT("IPCTEST");
		
		if (!RegisterClassEx(&wcex))
		{
			printf("failed to register IPCTEST window class\n");
			
			return 1;
		}
	}
	
	if (!(hwnd = CreateWindow(
		TEXT("IPCTEST"),
		TEXT(""),
		0,
		0,0,0,0,
		0,0,GetModuleHandle(0),0)))
	{
		printf("failed to create IPCTEST window\n");
		
		return 1;
	}
/*
	if (!sendquery(hwnd,TEXT("New Text Document.txt"))) 
	{
		return 1;
	}
*/
	if (!sendquery(hwnd,TEXT("Everything")))
	{
		return 1;
	}

	// message pump
loop:

	WaitMessage();
	
	// update windows
	while(PeekMessage(&msg,NULL,0,0,0)) 
	{
		ret = (int)GetMessage(&msg,0,0,0);
		if (ret == -1) goto exit;
		if (!ret) goto exit;
		
		// let windows handle it.
		TranslateMessage(&msg);
		DispatchMessage(&msg);
	}			
	
	goto loop;

exit:
	getchar();
		
	return 0;
}
