// MLXLCShim: LiveContainer tweak that points MeloNX's RAM donor lookup at the
// helper extension embedded in LiveContainer's own app bundle.
// Logs are prefixed with [MLXLCShim] and land in MeloNX's log output.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString *MLXHelperIDInAppDir(NSString *appDir)
{
    NSString *plugIns = [appDir stringByAppendingPathComponent:@"PlugIns"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugIns error:nil];

    for (NSString *name in names)
    {
        if (![name.pathExtension isEqualToString:@"appex"])
        {
            continue;
        }

        NSBundle *bundle = [NSBundle bundleWithPath:[plugIns stringByAppendingPathComponent:name]];
        NSString *principal = bundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"];

        if ([principal isEqualToString:@"MLXRamDonorHandler"] && bundle.bundleIdentifier)
        {
            return bundle.bundleIdentifier;
        }
    }

    return nil;
}

static NSString *MLXHostHelperID(void)
{
    static NSString *found;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *appDirs = [NSMutableArray array];

        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);

        if (size > 0)
        {
            char *buffer = malloc(size + 1);

            if (_NSGetExecutablePath(buffer, &size) == 0)
            {
                NSString *exe = [[NSString stringWithUTF8String:buffer] stringByResolvingSymlinksInPath];
                [appDirs addObject:exe.stringByDeletingLastPathComponent];
            }

            free(buffer);
        }

        NSString *arg0 = NSProcessInfo.processInfo.arguments.firstObject;

        if (arg0.length)
        {
            [appDirs addObject:arg0.stringByDeletingLastPathComponent];
        }

        CFBundleRef mainBundle = CFBundleGetMainBundle();
        CFURLRef mainURL = mainBundle ? CFBundleCopyBundleURL(mainBundle) : NULL;

        if (mainURL)
        {
            [appDirs addObject:((__bridge NSURL *)mainURL).path];
            CFRelease(mainURL);
        }

        for (NSString *dir in appDirs)
        {
            NSString *identifier = MLXHelperIDInAppDir(dir);
            NSLog(@"[MLXLCShim] looked in %@, helper: %@", dir, identifier ?: @"none");

            if (identifier)
            {
                found = identifier;
                break;
            }
        }
    });

    return found;
}

static id (*originalLookup)(id, SEL, NSString *, NSError **);

static id hookedLookup(id self, SEL _cmd, NSString *identifier, NSError **error)
{
    NSString *host = MLXHostHelperID();

    if (host && [identifier containsString:@"RamDonor"] && ![identifier isEqualToString:host])
    {
        NSLog(@"[MLXLCShim] redirecting %@ -> %@", identifier, host);
        identifier = host;
    }

    return originalLookup(self, _cmd, identifier, error);
}

__attribute__((constructor))
static void MLXLCShimInit(void)
{
    Class extensionClass = objc_getClass("NSExtension");
    Method method = extensionClass ? class_getClassMethod(extensionClass, @selector(extensionWithIdentifier:error:)) : NULL;

    if (!method)
    {
        NSLog(@"[MLXLCShim] NSExtension lookup method not found, nothing hooked");
        return;
    }

    originalLookup = (id (*)(id, SEL, NSString *, NSError **))method_getImplementation(method);
    method_setImplementation(method, (IMP)hookedLookup);

    NSLog(@"[MLXLCShim] loaded, lookup hooked");
}
