// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual header with syscall faults; no production test hooks.
#include "verified_received_seed.h"
#include <cstdarg>
#include <fstream>
#include <iostream>
#include <stdexcept>

namespace {
int linkError = 0, renameError = 0, replacingCalls = 0;
bool compete = false, symlinkCompetitor = false;
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void competitor(int directory, const char* name) {
    if (symlinkCompetitor) {
        require(::symlinkat("victim", directory, name) == 0, "create competing symlink");
    } else {
        const int fd = ::openat(directory, name, O_WRONLY | O_CREAT | O_EXCL, 0600);
        require(fd >= 0, "create competing destination");
        require(::write(fd, "other", 5) == 5, "write competing destination");
        ::close(fd);
    }
}
std::string contents(const std::filesystem::path& path) {
    std::ifstream input(path);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
}
extern "C" int __real_linkat(int, const char*, int, const char*, int);
extern "C" int __real_renameat(int, const char*, int, const char*);
extern "C" long __real_syscall(long, ...);
extern "C" int __wrap_linkat(int from, const char* source, int to, const char* target, int flags) {
    if (linkError) { errno = linkError; return -1; }
    return __real_linkat(from, source, to, target, flags);
}
extern "C" long __wrap_syscall(long number, ...) {
    require(number == SYS_renameat2, "unexpected wrapped syscall");
    va_list args;
    va_start(args, number);
    const int from = va_arg(args, int);
    const auto source = va_arg(args, const char*);
    const int to = va_arg(args, int);
    const auto target = va_arg(args, const char*);
    const int flags = va_arg(args, int);
    va_end(args);
    require(flags == RENAME_NOREPLACE, "rename must not replace");
    if (renameError) { errno = renameError; return -1; }
    if (compete) competitor(to, target);
    return __real_syscall(number, from, source, to, target, flags);
}
extern "C" int __wrap_renameat(int from, const char* source, int to, const char* target) {
    ++replacingCalls;
    // Deterministically occupy the name after the old fallback's absence check.
    if (compete) competitor(to, target);
    return __real_renameat(from, source, to, target);
}
int main() {
    char pattern[] = "/tmp/jami-received-publication-XXXXXX";
    const auto directory = ::mkdtemp(pattern);
    if (!directory) return 1;
    const std::filesystem::path root(directory);
    struct Cleanup { std::filesystem::path root; ~Cleanup() { std::filesystem::remove_all(root); } } cleanup{root};
    try {
        int cases = 0;
        const auto run = [&](int deniedLink, int unsupportedRename, bool racing, bool symlink, bool existing, bool replace, bool expected) {
            const auto work = root / std::to_string(++cases);
            std::filesystem::create_directory(work);
            std::ofstream(work / "victim") << "victim";
            if (existing) std::ofstream(work / "destination") << "other";
            jami::received_seed::File file(work / "partial", true);
            require(file.valid(), "create receive");
            require(file.write(reinterpret_cast<const unsigned char*>("received"), 8), "write receive");
            linkError = deniedLink; renameError = unsupportedRename; compete = racing;
            symlinkCompetitor = symlink; replacingCalls = 0;
            const bool result = file.publishTo(work / "destination", replace);
            require(result == expected, "publication outcome");
            require(replacingCalls == (replace ? 1 : 0), "nonreplacement never calls replacing rename");
            require(contents(work / "victim") == "victim", "symlink target preserved");
            if (expected) {
                require(contents(work / "destination") == "received", "published contents");
                require(!std::filesystem::exists(work / "partial"), "retired source");
            } else {
                require(contents(work / "partial") == "received", "failed publication preserves source");
                if (existing || (racing && !unsupportedRename)) {
                    require(symlink ? std::filesystem::is_symlink(work / "destination") : contents(work / "destination") == "other", "competitor preserved");
                } else require(!std::filesystem::exists(work / "destination"), "no failed destination");
            }
        };
        run(0, 0, false, false, false, false, true);
        run(0, 0, false, false, true, false, false);
        for (const int denied : {EPERM, EACCES}) {
            run(denied, 0, false, false, false, false, true);
            run(denied, 0, false, false, true, false, false);
            for (bool symlink : {false, true}) {
                run(denied, 0, true, symlink, false, false, false);
                for (const int unsupported : {EINVAL, ENOSYS, EOPNOTSUPP})
                    run(denied, unsupported, true, symlink, false, false, false);
            }
        }
        run(0, 0, false, false, true, true, true);
        std::cout << cases << " publication cases passed\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
