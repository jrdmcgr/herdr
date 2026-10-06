// Native app entry point. LaunchServices does not reliably apply LSEnvironment
// and cannot launch a shell script as CFBundleExecutable on this macOS version.
// Exec Ghostty inside the same bundle with this app's config explicitly.
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char path[PATH_MAX];
    uint32_t length = sizeof(path);
    if (_NSGetExecutablePath(path, &length) != 0) return 1;
    char *slash = strrchr(path, '/');
    if (slash == NULL) return 1;
    *slash = '\0';

    char ghostty[PATH_MAX], config[PATH_MAX], xdg[PATH_MAX];
    if (snprintf(ghostty, sizeof(ghostty), "%s/ghostty", path) >= (int)sizeof(ghostty) ||
        snprintf(config, sizeof(config), "--config-file=%s/../Resources/herdr.ghostty", path) >= (int)sizeof(config))
        return 1;

    const char *home = getenv("HOME");
    if (home == NULL || snprintf(xdg, sizeof(xdg), "%s/Library/Application Support/Herdr/installer/xdg", home) >= (int)sizeof(xdg))
        return 1;
    if (setenv("XDG_CONFIG_HOME", xdg, 1) != 0) return 1;

    char **args = calloc((size_t)argc + 2, sizeof(char *));
    if (args == NULL) return 1;
    args[0] = ghostty;
    args[1] = config;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
    execv(ghostty, args);
    perror("exec Ghostty");
    return 1;
}
