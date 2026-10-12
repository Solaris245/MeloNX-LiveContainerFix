// MLXLCShim: LiveContainer tweak that points MeloNX's RAM donor lookup at the
// helper extension embedded in LiveContainer's own app bundle.
// LiveContainer fakes the executable path and NSBundle.mainBundle for guest
// apps, so the host app is found by scanning every loaded image instead.
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

static void MLXAddAppDirForPath(NSString *path, NSMutableOrderedSet<NSString *> *dirs)
{
    if (!path.length || [path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/"])
    {
        return;
    }

    NSRange range = [path rangeOfString:@".app" options:NSBackwardsSearch];

    // only accept ".app" as a whole path component
    while (range.location != NSNotFound)
    {
        NSUInteger end = range.location + range.length;

        if (end == path.length || [path characterAtIndex:end] == '/')
        {
            [dirs addObject:[path substringToIndex:end]];
            return;
        }

        if (range.location == 0)
        {
            return;
        }

        range = [path rangeOfString:@".app" options:NSBackwardsSearch range:NSMakeRange(0, range.location)];
    }
}

// Every helper ID found in any app directory we can see (host and guest).
static NSArray<NSString *> *MLXAllHelperIDs(void)
{
    static NSArray<NSString *> *ids;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSMutableOrderedSet<NSString *> *dirs = [NSMutableOrderedSet orderedSet];

        for (uint32_t i = 0; i < _dyld_image_count(); i++)
        {
            const char *name = _dyld_get_image_name(i);

            if (name)
            {
                MLXAddAppDirForPath([NSString stringWithUTF8String:name], dirs);
            }
        }

        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);

        if (size > 0)
        {
            char *buffer = malloc(size + 1);

            if (_NSGetExecutablePath(buffer, &size) == 0)
            {
                MLXAddAppDirForPath([[NSString stringWithUTF8String:buffer] stringByResolvingSymlinksInPath], dirs);
            }

            free(buffer);
        }

        CFBundleRef mainBundle = CFBundleGetMainBundle();
        CFURLRef mainURL = mainBundle ? CFBundleCopyBundleURL(mainBundle) : NULL;

        if (mainURL)
        {
            MLXAddAppDirForPath(((__bridge NSURL *)mainURL).path, dirs);
            CFRelease(mainURL);
        }

        NSMutableArray<NSString *> *found = [NSMutableArray array];

        for (NSString *dir in dirs)
        {
            NSString *identifier = MLXHelperIDInAppDir(dir);
            NSLog(@"[MLXLCShim] looked in %@, helper: %@", dir, identifier ?: @"none");

            if (identifier && ![found containsObject:identifier])
            {
                [found addObject:identifier];
            }
        }

        ids = found;
    });

    return ids;
}

static id (*originalLookup)(id, SEL, NSString *, NSError **);

static id hookedLookup(id self, SEL _cmd, NSString *identifier, NSError **error)
{
    if ([identifier containsString:@"RamDonor"])
    {
        // MeloNX asks for its own (unregistered) helper. Swap in a helper
        // that belongs to a different app bundle, i.e. LiveContainer's.
        for (NSString *candidate in MLXAllHelperIDs())
        {
            if (![candidate isEqualToString:identifier])
            {
                NSLog(@"[MLXLCShim] redirecting %@ -> %@", identifier, candidate);
                identifier = candidate;
                break;
            }
        }
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
