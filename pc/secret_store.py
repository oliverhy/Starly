from __future__ import annotations

import base64
import ctypes
import os
from ctypes import wintypes


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _blob(data: bytes) -> tuple[DATA_BLOB, ctypes.Array[ctypes.c_char]]:
    buffer = ctypes.create_string_buffer(data)
    value = DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    return value, buffer


def protect_secret(value: str) -> str:
    if os.name != "nt":
        raise RuntimeError("StarlyBridge secret protection requires Windows DPAPI")
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(DATA_BLOB), wintypes.LPCWSTR, ctypes.POINTER(DATA_BLOB),
        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DATA_BLOB),
    ]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    source, source_buffer = _blob(value.encode("utf-8"))
    entropy, entropy_buffer = _blob(b"StarlyBridge-DPAPI-v1")
    output = DATA_BLOB()
    _ = (source_buffer, entropy_buffer)
    if not crypt32.CryptProtectData(
            ctypes.byref(source), "StarlyBridge", ctypes.byref(entropy),
            None, None, 0, ctypes.byref(output)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        encrypted = ctypes.string_at(output.pbData, output.cbData)
        return base64.b64encode(encrypted).decode("ascii")
    finally:
        kernel32.LocalFree(ctypes.cast(output.pbData, wintypes.HLOCAL))


def unprotect_secret(value: str) -> str:
    if os.name != "nt":
        raise RuntimeError("StarlyBridge secret protection requires Windows DPAPI")
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(DATA_BLOB), ctypes.POINTER(wintypes.LPWSTR),
        ctypes.POINTER(DATA_BLOB), ctypes.c_void_p, ctypes.c_void_p,
        wintypes.DWORD, ctypes.POINTER(DATA_BLOB),
    ]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    encrypted = base64.b64decode(value, validate=True)
    source, source_buffer = _blob(encrypted)
    entropy, entropy_buffer = _blob(b"StarlyBridge-DPAPI-v1")
    output = DATA_BLOB()
    description = wintypes.LPWSTR()
    _ = (source_buffer, entropy_buffer)
    if not crypt32.CryptUnprotectData(
            ctypes.byref(source), ctypes.byref(description), ctypes.byref(entropy),
            None, None, 0, ctypes.byref(output)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output.pbData, output.cbData).decode("utf-8")
    finally:
        if description:
            kernel32.LocalFree(ctypes.cast(description, wintypes.HLOCAL))
        kernel32.LocalFree(ctypes.cast(output.pbData, wintypes.HLOCAL))
