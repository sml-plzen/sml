#ifndef _Pre_notnull_
#define _Pre_notnull_
#endif

#include <tchar.h>
#include <windows.h>
#include <ncrypt_provider.h>
#include <stdio.h>

#ifndef NTE_NO_MORE_ITEMS
#define NTE_NO_MORE_ITEMS _HRESULT_TYPEDEF_(0x8009002A)
#endif

LPWSTR _tcstowstr(LPCTSTR strSource) {
	LPWSTR strTarget;

#ifndef _UNICODE
	DWORD bufferLen = MultiByteToWideChar(CP_ACP, 0, strSource, -1, NULL, 0);
	if (bufferLen == 0) {
		return NULL;
	}

	if ((strTarget = (LPWSTR)malloc(bufferLen * sizeof(wchar_t))) == NULL) {
		return NULL;
	}

	if (MultiByteToWideChar(CP_ACP, 0, strSource, -1, strTarget, bufferLen) != bufferLen) {
		free(strTarget);
		return NULL;
	}
#else
	strTarget = _tcsdup(strSource);
#endif

	return strTarget;
}

int _tmain(int argc, LPTSTR argv[]) {
	int exitValue;

	if (argc > 2) {
		_ftprintf(stderr, _T("At most one argument expected, got %d arguments ...\n"), argc - 1);
		exitValue = 2;
		goto exit;
	}

	HMODULE hModule;
	if ((hModule = LoadLibrary(_T("ncryptprov.dll"))) == NULL) {
		_ftprintf(stderr, _T("Could not load ncryptprov.dll ...\n"));
		exitValue = 1;
		goto exit;
	}

	GetKeyStorageInterfaceFn getKeyStorageInterface;
	if ((getKeyStorageInterface = (GetKeyStorageInterfaceFn)GetProcAddress(hModule, "GetKeyStorageInterface")) == NULL) {
		_ftprintf(stderr, _T("Could not obtain GetKeyStorageInterface function ...\n"));
		exitValue = 1;
		goto freeModule;
	}

	NCRYPT_KEY_STORAGE_FUNCTION_TABLE *pProvider;
	if (getKeyStorageInterface(L"", &pProvider, 1 /* local provider implementation */) != ERROR_SUCCESS) {
		_ftprintf(stderr, _T("Could not obtain provider interface ...\n"));
		exitValue = 1;
		goto freeModule;
	}

	NCRYPT_PROV_HANDLE hProvider;
	if (pProvider->OpenProvider(&hProvider, MS_KEY_STORAGE_PROVIDER, 0) != ERROR_SUCCESS) {
		_ftprintf(stderr, _T("Could not open provider ...\n"));
		exitValue = 1;
		goto freeModule;
	}

	if (argc == 1) {
		// list available local system keys
		for (PVOID enumState = NULL;;) {
			NCryptKeyName *pKeyName;
			SECURITY_STATUS status = pProvider->EnumKeys(hProvider, NULL, &pKeyName, &enumState, NCRYPT_MACHINE_KEY_FLAG);

			if (status != ERROR_SUCCESS) {
				if (enumState != NULL) {
					pProvider->FreeBuffer(enumState);
				}
				if (status != NTE_NO_MORE_ITEMS) {
					_ftprintf(stderr, _T("Could not enumerate keys ...\n"));
					exitValue = 1;
				} else {
					exitValue = 0;
				}
				break;
			}

			_tprintf(_T("%ls\n"), pKeyName->pszName);
			pProvider->FreeBuffer(pKeyName);
		}
	} else {
		LPWSTR keyName;
		if ((keyName = _tcstowstr(argv[1])) == NULL) {
			_ftprintf(stderr, _T("Could not copy key name ...\n"));
			exitValue = 1;
			goto freeProvider;
		}

		NCRYPT_KEY_HANDLE hKey;
		if (pProvider->OpenKey(hProvider, &hKey, keyName, 0, NCRYPT_MACHINE_KEY_FLAG) != ERROR_SUCCESS) {
			_ftprintf(stderr, _T("Could not open key ...\n"));
			exitValue = 1;
			goto freeKeyName;
		}

		if ((*((BYTE *)hKey + 0x24) & NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG) == 0) {
			// key is not exportable, we need to flip the exportable bit
			_ftprintf(stderr, _T("Marking key as exportable ...\n"));
			*((BYTE *)hKey + 0x24) |= NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG;
		}

		DWORD blobLen;
		SECURITY_STATUS status;
		LPCWSTR blobType;
		//blobType = LEGACY_RSAPRIVATE_BLOB;
		//blobType = BCRYPT_PRIVATE_KEY_BLOB;
		blobType = NCRYPT_PKCS8_PRIVATE_KEY_BLOB;
		if ((status = pProvider->ExportKey(hProvider, hKey, NULL, blobType, NULL, NULL, 0, &blobLen, 0)) != ERROR_SUCCESS) {
			_ftprintf(stderr, _T("Could not export key ... %08X\n"), status);
			exitValue = 1;
			goto freeKey;
		}
		_tprintf(_T("Key blob length: %d\n"), blobLen);

		PBYTE blob;
		if ((blob = (PBYTE)malloc(blobLen)) == NULL) {
			_ftprintf(stderr, _T("Could not allocate memory\n"));
			exitValue = 1;
			goto freeKey;
		}

		if ((status = pProvider->ExportKey(hProvider, hKey, NULL, blobType, NULL, blob, blobLen, &blobLen, 0)) != ERROR_SUCCESS) {
			_ftprintf(stderr, _T("Could not export key ... %08X\n"), status);
			exitValue = 1;
			goto freeBlob;
		}

		_TCHAR fileName[MAX_PATH];
		_sntprintf(fileName, sizeof(fileName)/sizeof(_TCHAR), _T("%ls.pem"), keyName);

		HANDLE hFile;
		if ((hFile = CreateFile(fileName, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL)) == INVALID_HANDLE_VALUE) {
			_ftprintf(stderr, _T("Could not create file ... %s\n"), fileName);
			exitValue = 1;
			goto freeBlob;
		}

		DWORD bytesWritten;
		if (!WriteFile(hFile, blob, blobLen, &bytesWritten, NULL) || bytesWritten != blobLen) {
			_ftprintf(stderr, _T("Could not write to file ... %s\n"), fileName);
			exitValue = 1;
		} else {
			_tprintf(_T("Wrote key blob to: %s\n"), fileName);
			exitValue = 0;
		}

		CloseHandle(hFile);
freeBlob:
		free(blob);
freeKey:
		pProvider->FreeKey(hProvider, hKey);
freeKeyName:
		free(keyName);
	}

freeProvider:
	pProvider->FreeProvider(hProvider);
freeModule:
	FreeLibrary(hModule);
exit:
	return exitValue;
}
