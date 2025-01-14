#include <string>
#include <iostream>
#include <algorithm>
#include "tclap/CmdLine.h"

using namespace TCLAP;
using namespace std;

int main(int argc, char **argv)
{
    // Wrap everything in a try block.  Do this every time,
    // because exceptions will be thrown for problems.
    try
    {

        // Define the command line object. 定义命令行对象  命令行描述消息 版本号
        CmdLine cmd("Command description message 命令行描述消息", "0.9");

        // Define a value argument and add it to the command line. 定义字符串类型参数值，并把它添加到命令行。
        ValueArg<string> nameArg("n", "name", "Name to print", true, "homer", "string");
        cmd.add( nameArg );

        // Define a switch and add it to the command line. 定义一个开关，并把它添加到命令行。
        SwitchArg reverseSwitch("r", "reverse", "Print name backwards", false);
        cmd.add( reverseSwitch );

        // Parse the args. 解析的args。
        cmd.parse( argc, argv );

        // Get the value parsed by each arg. 取得每个arg的值解析。
        string name = nameArg.getValue();
        bool reverseName = reverseSwitch.getValue();

        // Do what you intend too...
        if ( reverseName )
        {
            reverse(name.begin(), name.end());
            cout << "My name (spelled backwards) is: " << name << endl;
        }
        else
            cout << "My name is: " << name << endl;


    }
    catch (ArgException &e)    // catch any exceptions
    {
        cerr << "error: " << e.error() << " for arg " << e.argId() << endl;
    }
}

