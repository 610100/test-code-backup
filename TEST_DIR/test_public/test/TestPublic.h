#pragma once
#include "stdafx.h"

int TraceUtil();

int IniUtil();

int FileUtil();

//int TestFileVersionInfo();

int TestPathUtil();

int TestDirectoryTraversalUtil();

int TestRegUtil();

int TestSocket(TCHAR* pstrDomain, TCHAR* pstrIP);

int CheckIsEffective(char* pstrDomain, char* pstrIP);