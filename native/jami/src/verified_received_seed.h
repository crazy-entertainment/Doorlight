// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstring>
#include <deque>
#include <vector>
#include <cerrno>
#include <cstdint>
#include <filesystem>
#include <string>
#include <system_error>
#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif
#endif
#endif

namespace jami::received_seed {

// Hold every Windows ancestor against rename/reparse replacement. On POSIX,
// resolve each component with openat/O_NOFOLLOW and retain the final directory.
class Directory {
public:
    explicit Directory(const std::filesystem::path& path) {
        std::error_code error;
        path_ = std::filesystem::absolute(path, error);
        if (error || path_.empty()) return;
        for (const auto& part : path_.relative_path())
            if (part == "..") return;
#ifdef _WIN32
        auto current = path_.root_path();
        for (const auto& part : path_.relative_path()) {
            if (part == "." || part.empty()) continue;
            current /= part;
            const auto handle = CreateFileW(current.c_str(), FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (handle == INVALID_HANDLE_VALUE) return;
            handles_.push_back(handle);
            FILE_ATTRIBUTE_TAG_INFO info {};
            if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &info, sizeof(info)) ||
                !(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
                (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return;
        }
        valid_ = !handles_.empty();
#else
        // Ancestors need only search permission: Android denies apps read access
        // to "/" and intermediate system directories. The retained final
        // directory is opened readable so it can be fsynced after publication.
        std::deque<std::filesystem::path> parts;
        for (const auto& part : path_.relative_path())
            if (part != "." && !part.empty()) parts.push_back(part);
#ifdef O_PATH
        constexpr int ancestor = O_PATH;
#else
        constexpr int ancestor = O_RDONLY;
#endif
        handle_ = ::open("/", (parts.empty() ? O_RDONLY : ancestor) | O_DIRECTORY | O_CLOEXEC);
        if (handle_ < 0) return;
        int links = 0;
        while (!parts.empty()) {
            const auto part = parts.front();
            parts.pop_front();
            const int access = parts.empty() ? O_RDONLY : ancestor;
            const int next = ::openat(handle_, part.c_str(),
                access | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (next < 0 && (errno == ENOTDIR || errno == ELOOP) && ++links <= 40 &&
                unmodifiable(handle_)) {
                // Android 11+ app data isolation makes /data/user/0 a symlink in
                // a system tmpfs. Follow only links whose directory this process
                // cannot change; links in owned or writable directories still fail.
                struct stat info {};
                std::array<char, 4096> target {};
                if (::fstatat(handle_, part.c_str(), &info, AT_SYMLINK_NOFOLLOW) || !S_ISLNK(info.st_mode))
                    return;
                const auto length = ::readlinkat(handle_, part.c_str(), target.data(), target.size());
                if (length <= 0 || static_cast<size_t>(length) >= target.size()) return;
                const std::filesystem::path resolved(std::string(target.data(), static_cast<size_t>(length)));
                std::vector<std::filesystem::path> expanded;
                for (const auto& piece : resolved.relative_path())
                    if (piece != "." && !piece.empty()) expanded.push_back(piece);
                parts.insert(parts.begin(), expanded.begin(), expanded.end());
                if (resolved.is_absolute()) {
                    ::close(handle_);
                    handle_ = ::open("/", (parts.empty() ? O_RDONLY : ancestor) | O_DIRECTORY | O_CLOEXEC);
                    if (handle_ < 0) return;
                } else if (parts.empty()) {
                    return;
                }
                continue;
            }
            ::close(handle_);
            handle_ = next;
            if (handle_ < 0) return;
        }
        valid_ = true;
#endif
    }
    ~Directory() {
#ifdef _WIN32
        for (auto handle : handles_) CloseHandle(handle);
#else
        if (handle_ >= 0) ::close(handle_);
#endif
    }
    Directory(const Directory&) = delete;
    Directory& operator=(const Directory&) = delete;
    bool valid() const { return valid_; }
    const std::filesystem::path& path() const { return path_; }
#ifndef _WIN32
    int handle() const { return handle_; }
    bool current() const {
        Directory now(path_);
        struct stat prior {}, latest {};
        return valid_ && now.valid() && !::fstat(handle_, &prior) &&
            !::fstat(now.handle_, &latest) && prior.st_dev == latest.st_dev && prior.st_ino == latest.st_ino;
    }
#else
    bool current() const { return valid_; } // retained no-write/no-delete ancestor handles
#endif
private:
#ifndef _WIN32
    // A directory the process cannot write, rename within or re-permission.
    static bool unmodifiable(int directory) {
        struct stat info {};
        if (::fstat(directory, &info) || !S_ISDIR(info.st_mode)) return false;
        const auto user = ::geteuid();
        if (user == 0 || info.st_uid == user || (info.st_mode & S_IWOTH)) return false;
        if (!(info.st_mode & S_IWGRP)) return true;
        if (info.st_gid == ::getegid()) return false;
        const int count = ::getgroups(0, nullptr);
        if (count < 0) return false;
        std::vector<gid_t> groups(static_cast<size_t>(count));
        if (count && ::getgroups(count, groups.data()) != count) return false;
        for (const auto group : groups)
            if (group == info.st_gid) return false;
        return true;
    }
#endif
    std::filesystem::path path_;
    bool valid_ = false;
#ifdef _WIN32
    std::vector<HANDLE> handles_;
#else
    int handle_ = -1;
#endif
};

class File {
public:
    enum class Mode { read, create, append };
    File(const std::filesystem::path& path, bool create)
        : File(path, create ? Mode::create : Mode::read) {}
    File(const std::filesystem::path& path, Mode mode)
        : parent_(path.parent_path().empty() ? std::filesystem::path(".") : path.parent_path()),
          name_(path.filename()), writable_(mode != Mode::read) {
        if (!parent_.valid() || name_.empty() || name_ == "." || name_ == "..") return;
#ifdef _WIN32
        if (name_.wstring().find(L':') != std::wstring::npos) return;
        // DELETE access permits exact-handle publication and cleanup, never a
        // second path lookup after verification. Readers deny concurrent writes.
        handle_ = CreateFileW((parent_.path() / name_).c_str(),
            GENERIC_READ | (writable_ ? GENERIC_WRITE | DELETE : 0),
            FILE_SHARE_READ, nullptr,
            mode == Mode::create ? CREATE_NEW : mode == Mode::append ? OPEN_ALWAYS : OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) return;
        FILE_ATTRIBUTE_TAG_INFO attributes {};
        FILE_STANDARD_INFO standard {};
        if (GetFileType(handle_) != FILE_TYPE_DISK ||
            !GetFileInformationByHandleEx(handle_, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
            (attributes.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
            !GetFileInformationByHandleEx(handle_, FileStandardInfo, &standard, sizeof(standard)) ||
            standard.EndOfFile.QuadPart < 0 || (writable_ && standard.NumberOfLinks != 1)) { close(); return; }
        size_ = static_cast<uint64_t>(standard.EndOfFile.QuadPart);
        if (mode == Mode::append) {
            LARGE_INTEGER zero {};
            if (!SetFilePointerEx(handle_, zero, nullptr, FILE_END)) close();
        }
#else
        const int flags = mode == Mode::create ? O_RDWR | O_CREAT | O_EXCL :
                          mode == Mode::append ? O_RDWR | O_CREAT : O_RDONLY;
        handle_ = ::openat(parent_.handle(), name_.c_str(), flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
        struct stat info {};
        if (handle_ < 0) return;
        if (::fstat(handle_, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 ||
            (writable_ && info.st_nlink != 1)) { close(); return; }
        size_ = static_cast<uint64_t>(info.st_size);
        if (mode == Mode::append && ::lseek(handle_, 0, SEEK_END) < 0) close();
#endif
    }
    ~File() { close(); }
    File(const File&) = delete;
    File& operator=(const File&) = delete;
    bool valid() const {
#ifdef _WIN32
        return handle_ != INVALID_HANDLE_VALUE;
#else
        return handle_ >= 0;
#endif
    }
    uint64_t size() const { return size_; }
    std::string identity() const {
        if (!valid()) return {};
#ifdef _WIN32
        BY_HANDLE_FILE_INFORMATION info {};
        if (!GetFileInformationByHandle(handle_, &info)) return {};
        return std::to_string(info.dwVolumeSerialNumber) + ":" +
            std::to_string(info.nFileIndexHigh) + ":" + std::to_string(info.nFileIndexLow);
#else
        struct stat info {};
        if (::fstat(handle_, &info)) return {};
        return std::to_string(uint64_t(info.st_dev)) + ":" + std::to_string(uint64_t(info.st_ino));
#endif
    }
    bool rewind() {
        if (!valid()) return false;
#ifdef _WIN32
        LARGE_INTEGER zero {};
        return SetFilePointerEx(handle_, zero, nullptr, FILE_BEGIN) != FALSE;
#else
        return ::lseek(handle_, 0, SEEK_SET) == 0;
#endif
    }
    int read(unsigned char* buffer, unsigned size) {
#ifdef _WIN32
        DWORD count = 0;
        return ReadFile(handle_, buffer, size, &count, nullptr) ? static_cast<int>(count) : -1;
#else
        ssize_t count;
        do { count = ::read(handle_, buffer, size); } while (count < 0 && errno == EINTR);
        return static_cast<int>(count);
#endif
    }
    bool write(const unsigned char* buffer, unsigned size) {
        if (!valid() || !writable_) return false;
        unsigned offset = 0;
        while (offset < size) {
#ifdef _WIN32
            DWORD count = 0;
            if (!WriteFile(handle_, buffer + offset, size - offset, &count, nullptr) || !count) return false;
#else
            ssize_t count;
            do { count = ::write(handle_, buffer + offset, size - offset); } while (count < 0 && errno == EINTR);
            if (count <= 0) return false;
#endif
            offset += static_cast<unsigned>(count);
            size_ += static_cast<unsigned>(count);
        }
        return true;
    }
    bool flush() {
#ifdef _WIN32
        return valid() && FlushFileBuffers(handle_) != FALSE;
#else
        return valid() && ::fsync(handle_) == 0;
#endif
    }
    bool removeOwned() {
        if (!valid() || !writable_ || published_) return false;
#ifdef _WIN32
        FILE_DISPOSITION_INFO disposition {}; disposition.DeleteFile = TRUE;
        return SetFileInformationByHandle(handle_, FileDispositionInfo, &disposition, sizeof(disposition)) != FALSE;
#else
        return ownsName() && ::unlinkat(parent_.handle(), name_.c_str(), 0) == 0;
#endif
    }
    bool publishTo(const std::filesystem::path& destination, bool replace = false) {
        std::error_code error;
        const auto full = std::filesystem::absolute(destination, error);
        if (error || !valid() || !writable_ || !parent_.current() ||
            full.parent_path().lexically_normal() != parent_.path().lexically_normal() ||
            full.filename().empty() || full.filename() == "." || full.filename() == ".." ||
            !flush()) return false;
#ifdef _WIN32
        const auto target = full.wstring();
        std::vector<unsigned char> storage(sizeof(FILE_RENAME_INFO) + target.size() * sizeof(wchar_t));
        auto* info = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
        info->ReplaceIfExists = replace;
        info->RootDirectory = nullptr;
        info->FileNameLength = DWORD(target.size() * sizeof(wchar_t));
        std::memcpy(info->FileName, target.data(), info->FileNameLength);
        if (!SetFileInformationByHandle(handle_, FileRenameInfo, info, DWORD(storage.size()))) return false;
#else
        if (!ownsName()) return false;
        if (replace) {
            if (::renameat(parent_.handle(), name_.c_str(), parent_.handle(), full.filename().c_str())) return false;
        } else {
            // Link the held inode, not a name that can be swapped after hashing.
            const auto descriptor = "/proc/self/fd/" + std::to_string(handle_);
            if (::linkat(AT_FDCWD, descriptor.c_str(), parent_.handle(), full.filename().c_str(), AT_SYMLINK_FOLLOW)) {
                // Android SELinux denies apps hard links. Move the verified name
                // without replacement, then require it to still be the held inode.
                if (errno != EACCES && errno != EPERM) return false;
#if defined(__linux__) && defined(SYS_renameat2)
                if (::syscall(SYS_renameat2, parent_.handle(), name_.c_str(), parent_.handle(),
                              full.filename().c_str(), RENAME_NOREPLACE)) return false;
                // Never fall back to replacing rename, even when this filesystem
                // lacks flags: checking absence cannot reserve the destination.
                published_ = true;
                name_ = full.filename();
                return ownsName() && ::fsync(parent_.handle()) == 0;
#else
                return false;
#endif
            }
            if (ownsName()) ::unlinkat(parent_.handle(), name_.c_str(), 0);
        }
#endif
        published_ = true;
        name_ = full.filename();
#ifndef _WIN32
        if (::fsync(parent_.handle())) return false;
#endif
        return true;
    }
    void close() {
#ifdef _WIN32
        if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
        handle_ = INVALID_HANDLE_VALUE;
#else
        if (handle_ >= 0) ::close(handle_);
        handle_ = -1;
#endif
    }
private:
#ifndef _WIN32
    bool ownsName() const {
        struct stat opened {}, named {};
        return valid() && !::fstat(handle_, &opened) &&
            !::fstatat(parent_.handle(), name_.c_str(), &named, AT_SYMLINK_NOFOLLOW) &&
            S_ISREG(named.st_mode) && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino;
    }
    int handle_ = -1;
#else
    HANDLE handle_ = INVALID_HANDLE_VALUE;
#endif
    Directory parent_;
    std::filesystem::path name_;
    bool writable_ = false;
    bool published_ = false;
    uint64_t size_ = 0;
};

template<class Digest>
bool readVerified(File& source, uint64_t expectedSize, const std::string& expectedHash, File* output = nullptr) {
    if (!source.valid() || source.size() != expectedSize || expectedSize > 2ULL * 1024 * 1024 * 1024 || !source.rewind())
        return false;
    Digest digest;
    std::array<unsigned char, 64 * 1024> buffer {};
    uint64_t copied = 0;
    for (;;) {
        const int count = source.read(buffer.data(), static_cast<unsigned>(buffer.size()));
        if (count < 0) return false;
        if (count == 0) break;
        if (static_cast<uint64_t>(count) > expectedSize - copied) return false;
        digest.update(buffer.data(), static_cast<unsigned>(count));
        if (output && !output->write(buffer.data(), static_cast<unsigned>(count))) return false;
        copied += static_cast<uint64_t>(count);
    }
    return copied == expectedSize && digest.finish() == expectedHash && (!output || output->flush());
}

// The temporary path must be a newly generated direct child of the same owned
// seed directory. Publication never overwrites or removes an existing seed.
template<class Digest>
bool publish(const std::filesystem::path& sourcePath, const std::filesystem::path& seedPath,
             const std::filesystem::path& temporaryPath, uint64_t size, const std::string& hash) {
    if (hash.empty() || temporaryPath.parent_path() != seedPath.parent_path() ||
        temporaryPath == seedPath || temporaryPath == sourcePath) return false;
    File existing(seedPath, false);
    if (existing.valid()) return readVerified<Digest>(existing, size, hash);
    File source(sourcePath, false);
    if (!source.valid()) return false;
    File output(temporaryPath, true);
    if (!output.valid()) return false;
    bool verified = false;
    try { verified = readVerified<Digest>(source, size, hash, &output); }
    catch (...) { verified = false; }
    if (verified) verified = output.publishTo(seedPath);
    if (!verified) output.removeOwned();
    output.close();
    if (verified) {
        File published(seedPath, false);
        verified = readVerified<Digest>(published, size, hash);
    }
    return verified;
}
} // namespace jami::received_seed
