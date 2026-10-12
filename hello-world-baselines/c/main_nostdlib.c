typedef void *HANDLE;
typedef const void *LPCVOID;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef int BOOL;

#define STD_OUTPUT_HANDLE ((DWORD)-11)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD nStdHandle);
__declspec(dllimport) BOOL __stdcall WriteFile(
    HANDLE hFile,
    LPCVOID lpBuffer,
    DWORD nNumberOfBytesToWrite,
    DWORD *lpNumberOfBytesWritten,
    void *lpOverlapped
);
__declspec(dllimport) void __stdcall ExitProcess(UINT uExitCode);

void mainCRTStartup(void) {
    static const char message[] = "Hello, world!\r\n";
    DWORD written = 0;
    HANDLE stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    WriteFile(stdout_handle, message, (DWORD)(sizeof(message) - 1), &written, 0);
    ExitProcess(0);
}
