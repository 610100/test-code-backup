/*
 * Copyright Bruce Liang (ldcsaa@gmail.com)
 *
 * Version	: 2.1.1
 * Author	: Bruce Liang
 * Porject	: https://code.google.com/p/ldcsaa
 * Bolg		: http://www.cnblogs.com/ldcsaa
 * WeiBo	: http://weibo.com/u/1402935851
 * QQ Group	: http://qun.qq.com/#jointhegroup/gid/75375912
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
 
/******************************************************************************
Module:  Event.h
Notices: Copyright (c) 2006 Bruce Liang
Purpose: 封装Win32事件内核对象, 用于在设置及读取变量时同步线程.
Desc:
Usage:
******************************************************************************/

#pragma once
#include "GeneralHelper.h"
class CEvt
{
public:	
	//bManualReset  指定将事件对象创建成手动复原还是自动复原。
	//			    如果是TRUE，那么必须用ResetEvent函数来手工将事件的状态复原到无信号状态。
	//		        如果设置为FALSE，当事件被一个等待线程释放以后，系统将会自动将事件状态复原为无信号状态。
	//bInitialState	指定事件对象的初始状态。如果为TRUE，初始状态为有信号状态；否则为无信号状态
	//pszName       指定事件的对象的名称，是一个以0结束的字符串指针
	//pSecurity     确定返回的句柄是否可被子进程继承。如果值是NULL，此句柄不能被继承。
	CEvt(BOOL bManualReset = FALSE, BOOL bInitialState = FALSE, LPCTSTR pszName = nullptr, LPSECURITY_ATTRIBUTES pSecurity = nullptr)
	{
		m_hEvent = ::CreateEvent(pSecurity, bManualReset, bInitialState, pszName);
		ASSERT(IsValid());
	}

	~CEvt()
	{
		if(IsValid())
			VERIFY(::CloseHandle(m_hEvent));
	}

	//重新打开事件
	BOOL Open(DWORD dwAccess, BOOL bInheritHandle, LPCTSTR pszName)
	{
		if(IsValid())
			VERIFY(::CloseHandle(m_hEvent));

		m_hEvent = ::OpenEvent(dwAccess, bInheritHandle, pszName);
		return(IsValid());
	}
	
	//系统核心对象中的Event事件对象，在进程、线程间同步的时候是比较常用，发现它有两个出发函数，一个是SetEvent，还有一个PulseEvent，两者的区别是：
	//SetEvent为设置事件对象为有信号状态；而PulseEvent也是将指定的事件设为有信号状态，
	//不同的是如果是一个人工重设事件，正在等候事件的、被挂起的所有线程都会进入活动状态，函数随后将事件设回，并返回；
	//如果是一个 自动重设事件，则正在等候事件的、被挂起的单个线程会进入活动状态，事件随后设回无信号，并且函数返回。
	//也就是说在自动重置模式下PulseEvent和SetEvent的作用没有什么区别，但在手动模式下PulseEvent就有明显的不同，可以比较容易的控制程序是单步走，还是连续走。
	//如果让循环按要求执行一次就用PulseEvent，如果想让循环连续不停的运转就用SetEvent，在要求停止的地方发个ResetEvent就OK了。
	// 
	//PulseEvent使得事件变为已通知状态，然后又立即变为未通知状态，就像调用了SetEvent之后立即调用了ResetEvent一样。
	//由于在调用PulseEvent时无法知道任何线程的状态，因此该函数并不那么有用。	
	BOOL Pulse()	{return(::PulseEvent(m_hEvent));}

	//把指定的事件对象设置为无信号状态。
	BOOL Reset()	{return(::ResetEvent(m_hEvent));}
	//把指定的事件对象设置为有信号
	BOOL Set()		{return(::SetEvent(m_hEvent));}

	//等待  dwTimeout超时时间
	DWORD Wait(DWORD dwTimeout = INFINITE) {return ::WaitForSingleObject(m_hEvent, dwTimeout);}

	HANDLE& GetHandle	() 	{return m_hEvent;}
	operator HANDLE		()	{return m_hEvent;}
	HANDLE* operator &	()	{return &m_hEvent;}
	//检查事件是否已经创建
	BOOL IsValid		()	{return m_hEvent != nullptr;}

private:
	CEvt(const CEvt&);
	CEvt operator = (const CEvt&);

private:
	HANDLE m_hEvent;
};

