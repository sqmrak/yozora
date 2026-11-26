import re
import subprocess
import sys


def inspect(otool, path, nm=None):
    for arch, target in (("armv7", "5.0"), ("arm64", "7.0")):
        commands = subprocess.check_output([otool, "-arch", arch, "-l", path], text=True)
        versions = re.findall(r"cmd LC_VERSION_MIN_IPHONEOS\s+cmdsize \d+\s+version ([\d.]+)", commands)
        if versions != [target]:
            raise RuntimeError(f"{arch}: unexpected deployment targets {versions}")
        if commands.count("cmd LC_UUID\n") != 1:
            raise RuntimeError(f"{arch}: bytecode cache version requires one Mach-O UUID")
        if arch == "armv7" and ("cmd LC_UNIXTHREAD\n" not in commands or "cmd LC_MAIN\n" in commands):
            raise RuntimeError("armv7: ios 5 requires LC_UNIXTHREAD")
        libraries = subprocess.check_output([otool, "-arch", arch, "-L", path], text=True)
        paths = re.findall(r"^\s+(/\S+)\s+\(", libraries, re.MULTILINE)
        # OpenGLES is linked weakly: webgl needs it where it exists, and iOS 5 to 10 start the app on every device either way
        weak = set(re.findall(r"^\s+(/\S+)\s+\([^)]*, weak\)", libraries, re.MULTILINE))
        opengles = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
        if opengles in paths and opengles not in weak:
            raise RuntimeError(f"{arch}: OpenGLES must be linked weakly")
        # the tiles of arm64 from ios 11 are painted with Metal, linked weakly so ios 7 to 10 start the app, and the armv7 slice has none
        gpu = {"/System/Library/Frameworks/Metal.framework/Metal", "/System/Library/Frameworks/IOSurface.framework/IOSurface"}
        if arch == "arm64":
            strong = {path for path in paths if path in gpu and path not in weak}
            if strong:
                raise RuntimeError(f"{arch}: Metal and IOSurface must be linked weakly: {sorted(strong)}")
            paths = [path for path in paths if path not in gpu]
        elif gpu & set(paths):
            raise RuntimeError(f"{arch}: Metal and IOSurface belong to the arm64 slice only")
        paths = [path for path in paths if path != opengles]
        allowed = {"/usr/lib/libSystem.B.dylib", "/usr/lib/libobjc.A.dylib",
                   "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                   "/System/Library/Frameworks/Foundation.framework/Foundation"}
        if set(paths) - allowed or "/usr/lib/libSystem.B.dylib" not in paths:
            raise RuntimeError(f"{arch}: unexpected dependencies {paths}")
        if nm:
            imports = subprocess.check_output([nm, "-arch", arch, "-u", path], text=True)
            symbols = {line.split()[-1] for line in imports.splitlines() if line.strip()}
            unavailable = {"_clock_gettime", "_clock_gettime_nsec_np", "_aligned_alloc",
                           "___ulock_wait", "___ulock_wait2", "___ulock_wake",
                           "_mach_continuous_time", "_mach_approximate_time",
                           "_vm_kernel_page_size", "_CCRandomGenerateBytes", "_mkostemp",
                           "_openat", "_fchmodat", "_fstatat", "_utimensat", "_futimens",
                           "_pthread_cond_clockwait"}
            unavailable.update({"__dyld_get_image_uuid", "_dyld_image_header_containing_address"})
            unsafe = symbols & unavailable
            unsafe.update(symbol for symbol in symbols if symbol.startswith(("_os_log", "__os_log")))
            if unsafe:
                raise RuntimeError(f"{arch}: imports unavailable on the deployment target: {sorted(unsafe)}")
        print(f"{arch}: ios {target}, dependencies {', '.join(paths)}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: verify_core_ios.py OTOOL EXECUTABLE [NM]")
    inspect(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
